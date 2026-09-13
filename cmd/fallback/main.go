// Package main implements the Lambda handler for the apigw-transfer
// cache-miss fallback:
// GET/HEAD /files-delivery/{fileDeliveryId}/retrievals/{retrievalId}.
//
// Chamado só quando GET/HEAD /files-delivery/{fileDeliveryId}/files/{fileId}
// (API Gateway -> S3 Service Proxy, sem Lambda) não encontra o arquivo e
// redireciona pra cá -- ver SPEC.md seção 2/4 e ADR 0001. retrievalId é o
// próprio fileId, e a key no S3 é "{fileDeliveryId}/{fileId}". Simula o
// fallback assíncrono do desenho final (lá executado pelo BFF): a
// requisição nunca espera a cópia terminar.
//
// Requisição do API Gateway:
//  1. Arquivo já existe no S3 -> 302 pra rota files (sem lock).
//  2. Tenta o lock distribuído (S3) em UMA tentativa. Ocupado -> 202 +
//     Retry-After.
//  3. Com o lock: se o arquivo não existe na origem
//     ("origin/{fileDeliveryId}/{fileId}" no mesmo bucket) -> libera o lock
//     e responde 404 cacheável.
//  4. Senão dispara a cópia numa autoinvocação assíncrona
//     (InvocationType Event), que fica dona do lock, e responde 202 +
//     Retry-After -- inclusive pra quem pegou o lock.
//
// Invocação assíncrona ({"fileDeliveryId": ..., "fileId": ...}): copia a
// origem pro S3 em streaming, gravando o Cache-Control do canal (repassado
// pelo API Gateway nas respostas de files), e libera o lock.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/s3/transfermanager"
	lambdasvc "github.com/aws/aws-sdk-go-v2/service/lambda"
	lambdatypes "github.com/aws/aws-sdk-go-v2/service/lambda/types"
	s3svc "github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/smithy-go"

	storageadapters "github.com/brunojet/go-infra-adapters/v4/pkg/storage/aws/s3"
	storagecontracts "github.com/brunojet/go-infra-adapters/v4/pkg/storage/contracts"
)

const (
	defaultS3Bucket            = "brunojet-media-proxy-dev"
	defaultOriginPrefix        = "origin/"
	defaultLockTTL             = 360 // segundos -- deve ser >= timeout da Lambda (cobre a cópia assíncrona)
	defaultRetryAfterSecs      = 5   // segundos sugeridos ao cliente via Retry-After
	defaultNotFoundMaxAgeSecs  = 60  // usado só se a stage variable estiver ausente/inválida
	notFoundMaxAgeStageVarName = "notFoundMaxAgeSeconds"
)

// fileIDPattern restringe fileId a um segmento simples: nada de "/", ".."
// ou caracteres que mudariam a key montada no S3.
var fileIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

var (
	bucket     storagecontracts.BucketAdapter
	bucketName string
	// uploader grava o arquivo copiado com Cache-Control, que o adapter de
	// storage não expõe.
	uploader       *transfermanager.Client
	lambdaClient   *lambdasvc.Client
	functionName   string
	originPrefix   string
	lockTTL        time.Duration
	retryAfterSecs int
	// cacheControlByDelivery: canais aceitos (fileDeliveryId) e o
	// Cache-Control gravado no objeto de cada um.
	cacheControlByDelivery map[string]string
)

// copyJob é o payload da autoinvocação assíncrona que executa a cópia.
type copyJob struct {
	FileDeliveryID string `json:"fileDeliveryId"`
	FileID         string `json:"fileId"`
}

func (j copyJob) key() string { return j.FileDeliveryID + "/" + j.FileID }

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

	bucketName = getEnvOrDefault("S3_BUCKET", defaultS3Bucket)
	bucket, err = storageAPI.NewBucket(bucketName)
	if err != nil {
		log.Fatalf("failed to create bucket adapter: %v", err)
	}

	cfg, err := awsconfig.LoadDefaultConfig(context.Background())
	if err != nil {
		log.Fatalf("failed to load AWS config: %v", err)
	}
	uploader = transfermanager.New(s3svc.NewFromConfig(cfg))
	lambdaClient = lambdasvc.NewFromConfig(cfg)
	functionName = os.Getenv("AWS_LAMBDA_FUNCTION_NAME") // definida pelo runtime da Lambda

	if err := json.Unmarshal([]byte(os.Getenv("FILE_DELIVERIES")), &cacheControlByDelivery); err != nil || len(cacheControlByDelivery) == 0 {
		log.Fatalf("FILE_DELIVERIES must be a JSON object of fileDeliveryId -> Cache-Control: %v", err)
	}

	originPrefix = getEnvOrDefault("ORIGIN_PREFIX", defaultOriginPrefix)
	lockTTL = time.Duration(getEnvIntOrDefault("LOCK_TTL_SECONDS", defaultLockTTL)) * time.Second
	retryAfterSecs = getEnvIntOrDefault("RETRY_AFTER_SECONDS", defaultRetryAfterSecs)
}

// Handle recebe tanto a requisição do API Gateway (integração aws_proxy)
// quanto a autoinvocação assíncrona da cópia.
func Handle(ctx context.Context, payload json.RawMessage) (any, error) {
	var job copyJob
	if err := json.Unmarshal(payload, &job); err == nil && job.FileDeliveryID != "" && job.FileID != "" {
		runCopy(ctx, job)
		// nil mesmo em falha: um retry automático da invocação assíncrona
		// rodaria sem o lock (já liberado). O cliente reenvia a requisição e
		// dispara uma nova cópia.
		return nil, nil
	}

	var req events.APIGatewayProxyRequest
	if err := json.Unmarshal(payload, &req); err != nil {
		return nil, fmt.Errorf("unexpected payload: %w", err)
	}
	return handleRequest(ctx, req), nil
}

func handleRequest(ctx context.Context, req events.APIGatewayProxyRequest) events.APIGatewayProxyResponse {
	job := copyJob{
		FileDeliveryID: req.PathParameters["fileDeliveryId"],
		FileID:         req.PathParameters["retrievalId"],
	}
	if _, ok := cacheControlByDelivery[job.FileDeliveryID]; !ok {
		return errorResponse(http.StatusNotFound, fmt.Sprintf("unknown fileDeliveryId %q", job.FileDeliveryID))
	}
	if !fileIDPattern.MatchString(job.FileID) {
		return errorResponse(http.StatusBadRequest, "invalid retrievalId")
	}

	key := job.key()
	stage := req.RequestContext.Stage

	// Caminho comum: a cópia já terminou -- responde sem tocar no lock.
	if alreadyExists(ctx, key) {
		return redirectToFile(stage, job)
	}

	// Tentativa única, não bloqueante. Qualquer erro que não seja "lock
	// ocupado" (permissão, rede) é erro de verdade, não motivo pra esperar.
	if lockErr := bucket.GetLock(ctx, key, lockTTL); lockErr != nil {
		if storageadapters.IsLockHeld(lockErr) {
			return retryLaterResponse(fmt.Sprintf("fetch already in progress for %s", key))
		}
		return errorResponse(http.StatusInternalServerError, fmt.Sprintf("lock acquire failed for %s: %v", key, lockErr))
	}

	// A partir daqui o lock é nosso até ser entregue à cópia assíncrona.
	handedOff := false
	defer func() {
		if !handedOff {
			releaseLock(key)
		}
	}()

	// Corrida: pode ter sido populado entre a checagem acima e o lock.
	if alreadyExists(ctx, key) {
		return redirectToFile(stage, job)
	}

	originKey := originPrefix + key
	found, err := objectExists(ctx, originKey)
	if err != nil {
		return errorResponse(http.StatusInternalServerError, fmt.Sprintf("origin lookup failed for %s: %v", originKey, err))
	}
	if !found {
		return notFoundInOriginResponse(req, originKey)
	}

	if err := dispatchCopy(ctx, job); err != nil {
		return errorResponse(http.StatusInternalServerError, fmt.Sprintf("dispatch copy failed for %s: %v", key, err))
	}
	handedOff = true
	return retryLaterResponse(fmt.Sprintf("fetch started for %s", key))
}

// dispatchCopy dispara a cópia numa invocação assíncrona desta mesma
// função. Trabalho em goroutine não serve: nada garante que o container
// continue executando depois que o handler retorna.
func dispatchCopy(ctx context.Context, job copyJob) error {
	payload, err := json.Marshal(job)
	if err != nil {
		return err
	}
	_, err = lambdaClient.Invoke(ctx, &lambdasvc.InvokeInput{
		FunctionName:   aws.String(functionName),
		InvocationType: lambdatypes.InvocationTypeEvent,
		Payload:        payload,
	})
	return err
}

// runCopy copia origin/{fileDeliveryId}/{fileId} -> {fileDeliveryId}/{fileId}
// com o Cache-Control do canal e libera o lock recebido de handleRequest. O
// TTL do lock (>= timeout da função) cobre o caso de a invocação morrer
// antes do defer.
func runCopy(ctx context.Context, job copyJob) {
	key := job.key()
	defer releaseLock(key)
	start := time.Now()

	originKey := originPrefix + key
	obj := &storagecontracts.BucketObject{}
	if err := bucket.GetObject(ctx, originKey, obj); err != nil {
		log.Printf("COPY ERROR: get %s: %v", originKey, err)
		return
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

	if _, err := uploader.UploadObject(ctx, &transfermanager.UploadObjectInput{
		Bucket:       aws.String(bucketName),
		Key:          aws.String(key),
		Body:         obj.Body,
		ContentType:  aws.String(contentType),
		CacheControl: aws.String(cacheControlByDelivery[job.FileDeliveryID]),
	}); err != nil {
		log.Printf("COPY ERROR: put %s: %v", key, err)
		return
	}
	log.Printf("COPY OK: %s -> %s in %s", originKey, key, time.Since(start).Round(time.Millisecond))
}

func releaseLock(key string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := bucket.ReleaseLock(ctx, key); err != nil {
		log.Printf("lock release failed for %s: %v", key, err)
	}
}

func alreadyExists(ctx context.Context, key string) bool {
	found, _ := objectExists(ctx, key)
	return found
}

// objectExists distingue "não existe" (false, nil) de falha na consulta
// (false, err) -- só o primeiro justifica um 404 cacheável.
func objectExists(ctx context.Context, key string) (bool, error) {
	err := bucket.HeadObject(ctx, key, &storagecontracts.ObjectInfo{})
	if err == nil {
		return true, nil
	}
	var apiErr smithy.APIError
	if errors.As(err, &apiErr) && (apiErr.ErrorCode() == "NotFound" || apiErr.ErrorCode() == "NoSuchKey") {
		return false, nil
	}
	return false, err
}

// redirectToFile aponta o cliente de volta pra rota files (sem Lambda) --
// o arquivo já está no S3. O Location precisa do prefixo do stage (ex.:
// "/dev") porque é isso que a URL externa usa; a Lambda recebe só os
// parâmetros de path, então o stage vem do RequestContext.
func redirectToFile(stage string, job copyJob) events.APIGatewayProxyResponse {
	location := fmt.Sprintf("/%s/files-delivery/%s/files/%s", strings.Trim(stage, "/"), job.FileDeliveryID, job.FileID)
	return events.APIGatewayProxyResponse{
		StatusCode: http.StatusFound,
		Headers: map[string]string{
			"Location":      location,
			"Cache-Control": "no-cache, no-store, must-revalidate",
		},
		Body: "",
	}
}

// retryLaterResponse sinaliza que a cópia está em andamento (iniciada
// agora ou por outra requisição) e o cliente deve repetir a requisição
// original depois de Retry-After segundos. 202 Accepted: o pedido foi
// aceito, só ainda não terminou -- mais preciso que 503 (falha) ou 429
// (rate limit).
//
// Cache-Control usa o MESMO valor de Retry-After de propósito: os dois
// headers prometem a mesma coisa ("essa resposta vale por N segundos").
// Protege contra estouro de manada num arquivo popular sendo populado; o
// custo máximo é um cliente esperar até N segundos a mais.
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

// notFoundInOriginResponse responde 404 quando o arquivo não existe nem na
// origem simulada. Diferente dos erros transitórios (lock, permissão,
// rede), este caso não muda sozinho, por isso é a única resposta de erro
// com Cache-Control: max-age. O valor vem da stage variable
// notFoundMaxAgeSeconds, ajustável sem redeploy.
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
