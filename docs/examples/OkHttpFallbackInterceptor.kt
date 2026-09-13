package com.example.apigwtransfer

import okhttp3.CompressionInterceptor
import okhttp3.Gzip
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Response
import java.io.IOException

/**
 * Espera o Retry-After e repete a MESMA requisicao quando o /fallback/{key}
 * responde 202 (lock ja tomado por outra chamada). Nao trata redirect --
 * o OkHttp ja segue 302 sozinho por padrao (Location vem totalmente
 * resolvido pelo servidor via VTL, ver docs/client-behavior.md secao 3),
 * entao esse interceptor so cobre o que o OkHttp nao resolve nativamente.
 * Decisao de design: retenta a URL ORIGINAL (nao guarda o /fallback/{key}
 * a parte) -- ela cai de novo no 404->302->fallback ate resolver, igual ao
 * wrapper request() de scripts/download_range.py.
 *
 * A espera bloqueia a thread da chamada. Com execute() num worker de
 * background (ex.: WorkManager) isso e' o esperado; com enqueue() ocupa uma
 * thread do Dispatcher do OkHttp durante todo o Retry-After. A espera
 * respeita call.cancel().
 */
class FallbackRetryInterceptor(
    private val maxWaitMillis: Long = 120_000L,
) : Interceptor {

    @Throws(IOException::class)
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        var response = chain.proceed(request)
        val deadline = System.currentTimeMillis() + maxWaitMillis

        while (response.code == 202) {
            val retryAfterSeconds = response.header("Retry-After")?.toLongOrNull() ?: 5L
            response.close()

            if (System.currentTimeMillis() + retryAfterSeconds * 1000 > deadline) {
                throw IOException(
                    "202 (lock ocupado) por mais de ${maxWaitMillis / 1000}s -- desistindo"
                )
            }
            val wakeAt = System.currentTimeMillis() + retryAfterSeconds * 1000
            while (System.currentTimeMillis() < wakeAt) {
                if (chain.call().isCanceled()) throw IOException("Canceled")
                Thread.sleep(minOf(250L, wakeAt - System.currentTimeMillis()).coerceAtLeast(1L))
            }
            response = chain.proceed(request)
        }
        return response
    }
}

/**
 * Converte 412 (If-Match nao bateu -- objeto mudou de versao durante o
 * download, ver docs/client-behavior.md secao 6) numa excecao lancada no
 * mesmo lugar que detecta, em vez de devolver como resposta "normal" que
 * quem chama precisa lembrar de checar (mesmo raciocinio do get_range()
 * em scripts/download_range.py).
 */
class PreconditionFailedInterceptor : Interceptor {

    @Throws(IOException::class)
    override fun intercept(chain: Interceptor.Chain): Response {
        val response = chain.proceed(chain.request())
        if (response.code == 412) {
            response.close()
            throw IOException(
                "arquivo mudou durante o download (If-Match falhou, 412) -- " +
                    "recomece do zero com a versao atual (novo HEAD, novo ETag)"
            )
        }
        return response
    }
}

/**
 * client.newCall(request).execute() a partir daqui ja segue 302
 * transparente (OkHttp), espera 202 transparente (FallbackRetryInterceptor)
 * e lanca excecao em 412 (PreconditionFailedInterceptor) -- o chamador so
 * ve 200/206 (sucesso) ou uma excecao (erro terminal ou teto de espera
 * estourado). O loop de chunking + calculo de offset de resume + leitura/
 * escrita do ETag em disco continuam responsabilidade do app (nao cabem
 * num interceptor, que so enxerga uma request/response por vez) -- ver
 * download()/head() em scripts/download_range.py como referencia da mesma
 * logica em Python.
 */
val client = OkHttpClient.Builder()
    .addInterceptor(FallbackRetryInterceptor())
    .addInterceptor(PreconditionFailedInterceptor())
    // Compressao com Range: o gzip transparente padrao do OkHttp
    // (BridgeInterceptor) NAO e' ativado quando a requisicao tem header
    // Range, entao os chunks viriam sem compressao. O CompressionInterceptor
    // (OkHttp 5.2+) manda Accept-Encoding e descomprime independente do
    // Range. Em OkHttp 4.x seria preciso um interceptor proprio.
    .addInterceptor(CompressionInterceptor(Gzip))
    // followRedirects(true) e' o padrao -- nao precisa declarar
    .build()
