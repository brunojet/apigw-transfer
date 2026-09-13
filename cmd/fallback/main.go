// Package main implements the Lambda handler for the apigw-transfer
// cache-miss fallback: GET/HEAD /fallback/{key+}.
//
// Chamado só quando o proxy direto (GET/HEAD /{key+}, API Gateway -> S3
// Service Proxy, sem Lambda) responde 404 -- ver SPEC.md seção 2/4 e
// PLAN.md. Este Lambda:
//  1. Checa se o objeto já existe no path direto (barato, sem lock --
//     cobre o caso comum de uma invocação concorrente já ter terminado).
//  2. Se não existe, tenta o lock distribuído (S3) em UMA tentativa (não
//     bloqueante). Se já está travado por outra invocação, responde
//     202 + Retry-After na hora -- quem espera é o cliente (polling),
//     sem custo de Lambda parada.
//  3. Busca no prefixo "origin/" do mesmo bucket (origem simulada -- ver
//     memória de projeto).
//  4. Copia (streaming) pro path direto, sem prefixo.
//  5. Libera o lock e redireciona (302) pro path direto -- o cliente
//     refaz a chamada original, agora servida pelo proxy sem Lambda.
package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"

	storageadapters "github.com/brunojet/go-infra-adapters/v4/pkg/storage/aws/s3"
	storagecontracts "github.com/brunojet/go-infra-adapters/v4/pkg/storage/contracts"
)

const (
	defaultS3Bucket            = "brunojet-media-proxy-dev"
	defaultOriginPrefix        = "origin/"
	defaultLockTTL             = 45 // segundos -- deve ser < timeout da Lambda
	defaultRetryAfterSecs      = 5  // segundos sugeridos ao cliente via Retry-After
	defaultNotFoundMaxAgeSecs  = 60 // usado só se a stage variable estiver ausente/inválida
	notFoundMaxAgeStageVarName = "notFoundMaxAgeSeconds"
)

var (
	bucket         storagecontracts.BucketAdapter
	originPrefix   string
	lockTTL        time.Duration
	retryAfterSecs int
)

func getEnvOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getEnvIntOrDefault(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return def
}

func init() {
	storageAPI, err := storageadapters.NewStorageAPI()
	if err != nil {
		log.Fatalf("failed to initialize storage API: %v", err)
	}

	bucketName := getEnvOrDefault("S3_BUCKET", defaultS3Bucket)
	bucket, err = storageAPI.NewBucket(bucketName)
	if err != nil {
		log.Fatalf("failed to create bucket adapter: %v", err)
	}

	originPrefix = getEnvOrDefault("ORIGIN_PREFIX", defaultOriginPrefix)
	lockTTL = time.Duration(getEnvIntOrDefault("LOCK_TTL_SECONDS", defaultLockTTL)) * time.Second
	retryAfterSecs = getEnvIntOrDefault("RETRY_AFTER_SECONDS", defaultRetryAfterSecs)
}

// Handle is the Lambda handler entry point (API Gateway REST API proxy integration).
func Handle(ctx context.Context, req events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
	key := req.PathParameters["key"]
	if key == "" {
		return errorResponse(http.StatusBadRequest, "missing key path parameter"), nil
	}

	stage := req.RequestContext.Stage

	// Caminho comum: outra invocação já terminou -- responde sem tocar no lock.
	if alreadyExists(ctx, key) {
		return redirectToDirectPath(stage, key), nil
	}

	// Tentativa única, não bloqueante. Se já travado, devolve a espera pro
	// cliente (Retry-After) em vez de segurar a Lambda esperando. Qualquer
	// OUTRO erro (permissão, rede, etc.) não é "está ocupado" -- é um erro
	// de verdade, que esperar não resolve (ver memória de projeto).
	if lockErr := bucket.GetLock(ctx, key, lockTTL); lockErr != nil {
		if storageadapters.IsLockHeld(lockErr) {
			return retryLaterResponse(fmt.Sprintf("fetch already in progress for %s", key)), nil
		}
		return errorResponse(http.StatusInternalServerError, fmt.Sprintf("lock acquire failed for %s: %v", key, lockErr)), nil
	}
	defer func() {
		releaseCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if releaseErr := bucket.ReleaseLock(releaseCtx, key); releaseErr != nil {
			log.Printf("lock release failed for %s: %v", key, releaseErr)
		}
	}()

	// Corrida: pode ter sido populado entre a checagem acima e o lock.
	if alreadyExists(ctx, key) {
		return redirectToDirectPath(stage, key), nil
	}

	originKey := originPrefix + key
	obj := &storagecontracts.BucketObject{}
	if err := bucket.GetObject(ctx, originKey, obj); err != nil {
		return notFoundInOriginResponse(req, originKey), nil
	}
	defer func() {
		if closeErr := obj.Close(); closeErr != nil {
			log.Printf("failed to close origin body: %v", closeErr)
		}
	}()

	contentType := obj.Info.ContentType
	if contentType == "" {
		contentType = "application/octet-stream"
	}

	putErr := bucket.PutObject(ctx, &storagecontracts.BucketObject{
		Info: storagecontracts.ObjectInfo{
			Key:         key,
			ContentType: contentType,
		},
		Body: obj.Body,
	})
	if putErr != nil {
		return errorResponse(http.StatusInternalServerError, fmt.Sprintf("upload failed for %s: %v", key, putErr)), nil
	}

	return redirectToDirectPath(stage, key), nil
}

func alreadyExists(ctx context.Context, key string) bool {
	info := &storagecontracts.ObjectInfo{}
	return bucket.HeadObject(ctx, key, info) == nil
}

// redirectToDirectPath aponta o cliente de volta pro proxy direto
// (/{key+}, sem Lambda) -- o objeto já está lá. O Location precisa do
// prefixo do stage (ex.: "/dev") porque é isso que a URL externa de
// verdade usa -- a Lambda só vê a key crua via PathParameters, então o
// stage tem que vir do RequestContext, não pode ser inferido da key.
func redirectToDirectPath(stage, key string) events.APIGatewayProxyResponse {
	location := "/" + strings.Trim(stage, "/") + "/" + strings.TrimPrefix(key, "/")
	return events.APIGatewayProxyResponse{
		StatusCode: http.StatusFound,
		Headers: map[string]string{
			"Location":      location,
			"Cache-Control": "no-cache, no-store, must-revalidate",
		},
		Body: "",
	}
}

// retryLaterResponse sinaliza pro cliente que o fetch já está em
// andamento (outra invocação segura o lock) e ele deve tentar de novo
// depois de Retry-After segundos. 202 Accepted: o pedido foi entendido,
// só ainda não terminou -- mais preciso que 503 (que soa como falha) ou
// 429 (que soa como rate limit, não é o caso aqui). Evita a Lambda ficar
// bloqueada esperando o lock liberar.
//
// Cache-Control usa o MESMO valor de Retry-After (não uma constante
// separada) de propósito: os dois headers prometem a mesma coisa ("essa
// resposta vale por N segundos"), então usar a mesma variável garante que
// nunca ficam dessincronizados se alguém mudar RETRY_AFTER_SECONDS. Isso
// protege contra estouro de manada -- vários clientes perguntando pela
// mesma key popular enquanto ela está sendo populada -- sem custo de
// infra: um cliente bem-comportado já ia esperar esses N segundos de
// qualquer jeito antes de perguntar de novo; cachear só evita que outros
// clientes (ou um mal-comportado) reconsultem a Lambda antes da hora. O
// único custo é um cliente raro receber esse 202 cacheado por até N
// segundos a mais mesmo se o lock já tiver liberado antes disso -- atraso
// máximo de N segundos, não um erro.
func retryLaterResponse(detail string) events.APIGatewayProxyResponse {
	log.Printf("RETRY: %s", detail)
	return events.APIGatewayProxyResponse{
		StatusCode: http.StatusAccepted,
		Headers: map[string]string{
			"Content-Type":  "application/json",
			"Retry-After":   strconv.Itoa(retryAfterSecs),
			"Cache-Control": fmt.Sprintf("max-age=%d", retryAfterSecs),
		},
		Body: fmt.Sprintf(`{"status":202,"detail":%q,"retry_after_seconds":%d}`, detail, retryAfterSecs),
	}
}

// notFoundInOriginResponse responde 404 quando a key não existe nem na
// origem simulada. Diferente dos outros erros deste handler (falha de
// lock/permissão/rede, upload -- todos transitórios, podem funcionar na
// próxima tentativa), este caso NÃO muda sozinho: só um humano populando
// origin/{key} resolve. Por isso é a ÚNICA resposta com Cache-Control:
// max-age -- protege contra clientes (de qualquer app, agregado) batendo
// repetidamente numa key que sabemos que vai continuar falhando, sem
// custo de infra (é só um header; cache de fato, se algum dia justificar
// o custo, é decisão separada -- ver SPEC.md). O valor vem de uma stage
// variable (notFoundMaxAgeSeconds), não de env var/redeploy, pelo mesmo
// motivo do maxChunkBytes do apigw_s3_proxy: ajustável sem tocar no
// código. As respostas transitórias (500) e o 202 (lock ocupado) NÃO
// ganham esse header de propósito -- cachear uma falha transitória
// estenderia a indisponibilidade além do problema real.
func notFoundInOriginResponse(req events.APIGatewayProxyRequest, originKey string) events.APIGatewayProxyResponse {
	detail := fmt.Sprintf("object not found in origin: %s", originKey)
	log.Printf("ERROR: %d - %s", http.StatusNotFound, detail)
	return events.APIGatewayProxyResponse{
		StatusCode: http.StatusNotFound,
		Headers: map[string]string{
			"Content-Type":  "application/json",
			"Cache-Control": fmt.Sprintf("max-age=%d", notFoundMaxAgeSeconds(req)),
		},
		Body: fmt.Sprintf(`{"status":%d,"detail":%q}`, http.StatusNotFound, detail),
	}
}

// notFoundMaxAgeSeconds lê a stage variable notFoundMaxAgeSeconds; um
// valor ausente ou inválido (não numérico, negativo) cai no default.
func notFoundMaxAgeSeconds(req events.APIGatewayProxyRequest) int {
	if v, ok := req.StageVariables[notFoundMaxAgeStageVarName]; ok {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			return n
		}
	}
	return defaultNotFoundMaxAgeSecs
}

func errorResponse(statusCode int, detail string) events.APIGatewayProxyResponse {
	log.Printf("ERROR: %d - %s", statusCode, detail)
	return events.APIGatewayProxyResponse{
		StatusCode: statusCode,
		Headers:    map[string]string{"Content-Type": "application/json"},
		Body:       fmt.Sprintf(`{"status":%d,"detail":%q}`, statusCode, detail),
	}
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM)
	defer stop()

	lambda.StartWithOptions(Handle, lambda.WithContext(ctx))
}
