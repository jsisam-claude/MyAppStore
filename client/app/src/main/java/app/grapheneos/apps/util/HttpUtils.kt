package app.grapheneos.apps.util

import android.net.Network
import java.net.HttpURLConnection
import java.net.ProtocolException
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import org.grapheneos.tls.ModernTLSSocketFactory

private val tlsSocketFactory = ModernTLSSocketFactory()

fun openConnection(network: Network?, urlString: String, configure: HttpURLConnection.() -> Unit): ScopedHttpConnection {
    val url = URL(urlString)
    val connection = if (network != null) {
        network.openConnection(url)
    } else {
        url.openConnection()
    } as HttpsURLConnection

    connection.apply {
        sslSocketFactory = tlsSocketFactory
        connectTimeout = 10_000
        readTimeout = 30_000
        // The repository is served from a single origin. Following a redirect
        // would resend the repository access key to whatever host it points at,
        // so treat any redirect as an error instead.
        instanceFollowRedirects = false
    }

    connection.configure()
    // Applied after configure() so that a caller cannot drop it.
    RepoAuth.attach(connection, urlString)
    connection.connect()
    return ScopedHttpConnection(connection)
}

class ScopedHttpConnection(val v: HttpURLConnection) : AutoCloseable {
    override fun close() {
        v.disconnect()
    }
}

fun throwResponseCodeException(conn: HttpURLConnection): Nothing {
    throw ProtocolException("Unexpected HTTP response: ${conn.responseCode} ${conn.responseMessage}, when connecting to ${conn.url}")
}
