import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLRequest lives here on Linux
#endif

/// The upload half of the NOOP to Databricks export: where each CSV goes, the request that carries it and
/// what an HTTP answer means. Pure (no networking) so the rules are pinned by DatabricksUploadTests; the
/// "Upload to Databricks" App Intent does the PUTs with these.
///
/// The files go to the user's own Unity Catalog volume through the Files API:
/// `PUT https://<workspace>/api/2.0/fs/files/Volumes/<catalog>/noop/raw/<file>?overwrite=true` with the
/// user's personal access token as a bearer token. Only a Databricks workspace host is accepted, so the
/// action can never be pointed at another server, whatever is typed into it. The token is used for the
/// requests of one run and never stored or logged by NOOP.
public enum DatabricksUpload {

    /// Schema and volume inside the user's catalog, the ones `Tools/databricks/noop_refresh.sql` creates.
    public static let schema = "noop"
    public static let volume = "raw"

    /// Host suffixes of Databricks workspaces (AWS and GCP under databricks.com, Azure under its own domain).
    static let workspaceHostSuffixes = [".databricks.com", ".azuredatabricks.net"]

    /// The https origin of a workspace typed by the user, with or without `https://`, a trailing slash, a
    /// path or a query (a copied browser address carries `?o=…`). nil unless the host is a Databricks
    /// workspace host and the scheme, when given, is https.
    public static func workspaceOrigin(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("https://") && !text.lowercased().hasPrefix("http://") {
            text = "https://" + text
        }
        guard let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), !host.isEmpty,
              workspaceHostSuffixes.contains(where: { host.hasSuffix($0) && host.count > $0.count })
        else { return nil }
        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        return origin.url
    }

    /// A Unity Catalog name the URL path can carry as is: letters, digits and underscores.
    public static func isValidCatalog(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || $0 == "_")
        }
    }

    /// The token as pasted, without surrounding spaces and without a leading "Bearer " a user may have
    /// copied along; nil when nothing is left.
    public static func cleanToken(_ raw: String) -> String? {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased() == "bearer" { return nil }
        if token.lowercased().hasPrefix("bearer ") {
            token = String(token.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
        }
        return token.isEmpty ? nil : token
    }

    /// Where one export file goes. nil for a catalog or file name the path could not carry safely (the
    /// export's own names are `<table>__yyyyMMdd-HHmmss.csv`).
    public static func fileURL(origin: URL, catalog: String, fileName: String) -> URL? {
        guard isValidCatalog(catalog), !fileName.isEmpty, !fileName.hasPrefix("."),
              fileName.unicodeScalars.allSatisfy({
                  ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || "_-.".unicodeScalars.contains($0))
              }),
              var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        else { return nil }
        parts.path = "/api/2.0/fs/files/Volumes/\(catalog)/\(schema)/\(volume)/\(fileName)"
        parts.queryItems = [URLQueryItem(name: "overwrite", value: "true")]
        return parts.url
    }

    /// The PUT that uploads one file: bearer token, raw bytes as the body.
    public static func request(url: URL, token: String, body: Data) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    /// Why a response is a failure, or nil for success (any 2xx; the Files API answers 204 No Content).
    public enum Failure: Equatable, Sendable {
        /// 401 / 403: the token is wrong, incomplete or expired, or lacks rights on the volume.
        case unauthorized(Int)
        /// 404: no such catalog, schema or volume.
        case notFound
        /// Any other non-2xx answer.
        case http(Int)
    }

    /// The reason Databricks gives in an error body, for the message the user sees: `ERROR_CODE: message`
    /// from its JSON error (`{"error_code": …, "message": …}`), else the start of a plain-text body, else "".
    /// One line, at most 300 characters, and anything shaped like an access token (`dapi` + hex) masked, so
    /// the message can be screenshotted safely. A 403 says whether the token or a permission is the problem.
    public static func errorDetail(from body: Data) -> String {
        var text = ""
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let code = (object["error_code"] as? String) ?? ""
            let message = (object["message"] as? String) ?? ""
            text = [code, message].filter { !$0.isEmpty }.joined(separator: ": ")
        } else if let plain = String(data: body.prefix(2_000), encoding: .utf8) {
            text = plain
        }
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        text = text.replacingOccurrences(of: #"dapi[0-9A-Fa-f-]{6,}"#, with: "dapi…", options: .regularExpression)
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }

    public static func failure(forStatus code: Int) -> Failure? {
        switch code {
        case 200..<300: return nil
        case 401, 403: return .unauthorized(code)
        case 404: return .notFound
        default: return .http(code)
        }
    }
}
