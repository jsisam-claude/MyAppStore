package app.grapheneos.apps.util

import app.grapheneos.apps.BuildConfig
import java.net.HttpURLConnection

/**
 * Phase 1 access control for the self-hosted repository: a static key sent as an
 * HTTP header on every request. nginx rejects requests that do not carry it.
 *
 * This is an access gate, not user authentication. The key ships inside the APK,
 * so anyone who can read the APK can read the key. It keeps the repository off
 * the open internet and gives a coarse revocation lever; it does not identify
 * users and does not survive a determined attacker with a copy of the app.
 * See docs/security.md.
 *
 * Repository contents stay protected by the Ed25519 signature over the metadata
 * and the SHA-256 digests that metadata commits to, independently of this key.
 */
object RepoAuth {
    private const val HEADER_NAME = BuildConfig.REPO_ACCESS_KEY_HEADER
    private const val KEY = BuildConfig.REPO_ACCESS_KEY

    val isEnabled = KEY.isNotEmpty()

    /** Attaches the key if [url] points at the configured repository. */
    fun apply(connection: HttpURLConnection, url: String) {
        if (isEnabled && isRepoUrl(url)) {
            connection.setRequestProperty(HEADER_NAME, KEY)
        }
    }

    /** Same gate, for HTTP stacks that are not [HttpURLConnection] (image loading). */
    fun headers(url: String): Map<String, String> =
        if (isEnabled && isRepoUrl(url)) mapOf(HEADER_NAME to KEY) else emptyMap()

    // REPO_BASE_URL is validated at build time to be an https:// URL with no
    // trailing slash. Requiring the '/' separator stops a lookalike host such as
    // https://repo.example.com.attacker.test/ from matching the prefix.
    private fun isRepoUrl(url: String) = url.startsWith(BuildConfig.REPO_BASE_URL + "/")
}
