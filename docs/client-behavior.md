# Comportamento esperado do cliente

Este documento descreve o contrato que qualquer cliente (biblioteca, SDK,
script) precisa seguir pra consumir o proxy `apigw-transfer` corretamente.
Complementa o [SPEC.md](../SPEC.md) (arquitetura) e o [PLAN.md](../PLAN.md)
(fases) — aqui o foco é só "o que o cliente deve fazer", não como o
servidor é montado.

## 1. Visão geral do contrato

- **Descoberta de tamanho:** `HEAD /{key}` sempre primeiro.
- **Download:** `GET /{key}` com header `Range`, em blocos (nunca sem
  `Range` — ver SPEC.md seção 5, teto de payload do API Gateway).
- **Cache-miss:** se `/{key}` responder `404`, o servidor responde `302`
  com um `Location` **já totalmente resolvido** (ex.:
  `/dev/fallback/apigw-transfer-fallback-test.bin`, montado dinamicamente
  no servidor via VTL — ver módulo `apigw_s3_proxy`). O cliente pode
  **seguir esse redirect automaticamente**, igual qualquer `302` HTTP
  normal (`curl -L`, browsers, a maioria das libs fazem isso sozinhas) —
  não precisa montar nem resolver nada manualmente.
- **Concorrência:** se `/fallback/{key}` responder `202`, o cliente
  **precisa** respeitar o header `Retry-After` antes de tentar de novo —
  não é opcional, é o mecanismo que evita custo duplicado de Lambda.

## 2. Caminho feliz — arquivo já existe

```mermaid
sequenceDiagram
    participant C as Cliente
    participant AGW as API Gateway
    participant S3 as S3 (bucket)

    C->>AGW: HEAD /{key}
    AGW->>S3: HeadObject(key)
    S3-->>AGW: 200, Content-Length=N
    AGW-->>C: 200, Content-Length=N

    loop enquanto offset < N
        C->>AGW: GET /{key}  Range: bytes=X-Y
        AGW->>S3: GetObject(key, Range)
        S3-->>AGW: 206, Content-Range
        AGW-->>C: 206, chunk binário
    end
    Note over C: reconstrói o arquivo concatenando os chunks
```

## 3. Cache-miss — arquivo existe na origem simulada

```mermaid
sequenceDiagram
    participant C as Cliente
    participant AGW as API Gateway
    participant S3d as S3 (path direto)
    participant L as Lambda fallback
    participant S3o as S3 (origin/)

    C->>AGW: HEAD /{key}
    AGW->>S3d: HeadObject(key)
    S3d-->>AGW: 404 NoSuchKey
    AGW-->>C: 302, Location: /{stage}/fallback/{key} (já resolvido)

    Note over C: cliente só segue o redirect (automático)

    C->>AGW: GET /fallback/{key}
    AGW->>L: invoke (Lambda proxy)
    L->>S3d: HeadObject(key) — corrida com outra invocação?
    S3d-->>L: 404 (não existe ainda)
    L->>S3d: GetLock(key) — tentativa única
    S3d-->>L: lock adquirido
    L->>S3o: GetObject(origin/key)
    S3o-->>L: 200, stream
    L->>S3d: PutObject(key, stream)
    S3d-->>L: 200
    L->>S3d: ReleaseLock(key)
    L-->>AGW: 302, Location: /{stage}/{key}
    AGW-->>C: 302, Location: /{stage}/{key}

    Note over C: segue o Location — volta pro caminho feliz

    C->>AGW: HEAD /{key}
    AGW->>S3d: HeadObject(key)
    S3d-->>AGW: 200, Content-Length=N
    AGW-->>C: 200
```

## 4. Concorrência — dois clientes pedem a mesma key ao mesmo tempo

```mermaid
sequenceDiagram
    participant A as Cliente A
    participant B as Cliente B
    participant AGW as API Gateway
    participant L as Lambda fallback
    participant S3 as S3

    par quase simultâneo
        A->>AGW: GET /fallback/{key}
        AGW->>L: invoke (A)
    and
        B->>AGW: GET /fallback/{key}
        AGW->>L: invoke (B)
    end

    L->>S3: GetLock(key)  [invocação de A processa primeiro]
    S3-->>L: lock adquirido (A)
    L->>S3: GetLock(key)  [invocação de B]
    S3-->>L: lock já existe (B)

    L-->>AGW: 202, Retry-After: 5   (resposta pra B)
    AGW-->>B: 202, Retry-After: 5
    Note over B: aguarda 5s antes de tentar de novo

    Note over L: invocação de A segue buscando + subindo pro S3
    L->>S3: fetch origin/key + PutObject(key)
    S3-->>L: OK
    L-->>AGW: 302, Location: /{stage}/{key}   (resposta pra A)
    AGW-->>A: 302, Location: /{stage}/{key}

    B->>AGW: GET /fallback/{key}  (retry após 5s)
    AGW->>L: invoke (B, 2ª tentativa)
    L->>S3: HeadObject(key) — já existe (A terminou)
    S3-->>L: 200
    L-->>AGW: 302, Location: /{stage}/{key}   (sem refazer o fetch)
    AGW-->>B: 302, Location: /{stage}/{key}
```

## 5. Fluxo de decisão do cliente

```mermaid
flowchart TD
    A["HEAD /key"] --> B{status}
    B -->|200| C["Content-Length conhecido"]
    C --> D["GET /key  Range: bytes=offset-offset+chunk"]
    D --> E{status}
    E -->|206| F{offset < total?}
    F -->|sim| D
    F -->|não| G["download completo"]
    E -->|500 / timeout| H["erro transitório -- retry com backoff"]
    H --> D

    B -->|302 / 404| I["monta /fallback/key"]
    I --> J["GET /fallback/key"]
    J --> K{status}
    K -->|302| L["segue Location"]
    L --> A
    K -->|202| M["espera Retry-After segundos"]
    M --> J
    K -->|404| N["objeto não existe nem na origem -- erro permanente, não faz retry"]
    K -->|500| H
```

## 6. Regras de comportamento (normativas)

| Situação | O cliente DEVE |
|---|---|
| Antes de baixar | Sempre fazer `HEAD /{key}` primeiro pra saber o tamanho total. |
| Download | Sempre usar `Range` — nunca `GET` sem `Range` num objeto que pode passar do teto de payload do API Gateway (ver SPEC.md §5). |
| Tamanho de chunk | Usar no máximo **8 MiB** por chunk — validado ponta a ponta (Fase 3); tamanhos maiores tiveram comportamento instável nos nossos testes. |
| `404`/`302` no path direto | Seguir o `Location` — já vem resolvido (path real, sem template) e pode ser seguido automaticamente como qualquer redirect HTTP. |
| `202` no `/fallback/{key}` | **Obrigatório** respeitar o `Retry-After` (segundos) antes de tentar de novo. Não fazer polling mais frequente que isso — é o mecanismo que evita concorrência desnecessária de Lambda. |
| `302` no `/fallback/{key}` | Seguir o `Location` (path relativo, já inclui o stage) — geralmente volta pro path direto, que agora deve responder `200`/`206`. |
| `404` no `/fallback/{key}` | Erro **permanente** — o objeto não existe nem na origem simulada. Não adianta repetir. |
| `500` (qualquer endpoint) | Erro transitório — retry com backoff exponencial (ex.: 1s, 2s, 4s..., com teto e número máximo de tentativas). |
| Timeout de rede | Tratar como erro transitório — retry com backoff, igual a um 500. |
| Consistência entre chunks | Guardar o `ETag` do `HEAD` inicial e mandar `If-Match: <etag>` em todo `GET` com `Range` — se o arquivo mudar no meio do download, o S3 responde `412 Precondition Failed` (o servidor repassa isso, não mascara como 200). |
| `412` num chunk | Erro **permanente pro download em andamento** — o objeto mudou de versão no meio do processo. Não adianta retentar o mesmo chunk; é preciso descartar o que já foi baixado e recomeçar do zero com a versão atual (novo `HEAD`, novo `ETag`). |
| Retomar download interrompido | Guardar o `ETag` junto com o arquivo parcial (ex.: sidecar `<arquivo>.etag`). Ao retomar: fazer `HEAD` de novo — se o `ETag` bater com o salvo, continuar do byte onde parou (`Range` começando do tamanho atual do arquivo local); se não bater, descartar o parcial e recomeçar do zero. |

## 7. Limites conhecidos (não normativo, mas relevante pro cliente)

- O teto de payload do API Gateway é **rígido**: ultrapassar causa falha
  abrupta (não é "entrega parcial e avisa"). Por isso o chunk de 8 MiB é
  uma recomendação forte, não só uma otimização.
- `binary_media_types` precisa estar configurado no servidor com os
  content-types reais que ele serve (não vazio, e não é obrigatório ser
  `"*/*"`) pra o corpo binário vir intacto — sem isso, o conteúdo vem
  corrompido (não é "só" inflado, ver SPEC.md §5). Isso é responsabilidade
  do servidor, mas o cliente deve validar a integridade do arquivo
  reconstruído (comparar tamanho final com o `Content-Length` do `HEAD`,
  e idealmente usar o mecanismo de `If-Match`/`ETag` acima) — não assumir
  que o corpo veio correto sem checar.
- Não há garantia de quanto tempo o fallback demora pra popular um
  arquivo grande — depende do tamanho do arquivo na origem simulada. O
  cliente deve ter um teto razoável de tentativas/tempo total antes de
  desistir e reportar erro pro usuário final, em vez de fazer polling
  indefinidamente.
