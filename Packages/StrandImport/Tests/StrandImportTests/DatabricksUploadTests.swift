import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLRequest lives here on Linux
#endif
@testable import StrandImport

final class DatabricksUploadTests: XCTestCase {

    func testWorkspaceOriginAcceptsTheWaysAnAddressGetsPasted() {
        let want = "https://dbc-3bd6eb88-b505.cloud.databricks.com"
        for typed in ["dbc-3bd6eb88-b505.cloud.databricks.com",
                      "https://dbc-3bd6eb88-b505.cloud.databricks.com",
                      " https://dbc-3bd6eb88-b505.cloud.databricks.com/ ",
                      "https://DBC-3bd6eb88-b505.cloud.databricks.com/?o=7474659485005382",
                      "https://dbc-3bd6eb88-b505.cloud.databricks.com/browse/folders/1"] {
            XCTAssertEqual(DatabricksUpload.workspaceOrigin(typed)?.absoluteString, want, typed)
        }
        XCTAssertEqual(DatabricksUpload.workspaceOrigin("adb-123.4.azuredatabricks.net")?.absoluteString,
                       "https://adb-123.4.azuredatabricks.net")
    }

    /// The files only ever go to a Databricks workspace over https.
    func testWorkspaceOriginRejectsAnyOtherServer() {
        for typed in ["", "   ", "http://dbc-1.cloud.databricks.com", "https://example.com",
                      "https://databricks.com.evil.example", "https://evil-databricks.com",
                      "https://.databricks.com", "ftp://dbc-1.cloud.databricks.com"] {
            XCTAssertNil(DatabricksUpload.workspaceOrigin(typed), typed)
        }
    }

    func testFileURLIsTheFilesApiPathInTheUsersVolume() throws {
        let origin = try XCTUnwrap(DatabricksUpload.workspaceOrigin("dbc-1.cloud.databricks.com"))
        let url = DatabricksUpload.fileURL(origin: origin, catalog: "noop_uploads",
                                           fileName: "days__20261102-100000.csv")
        XCTAssertEqual(url?.absoluteString,
                       "https://dbc-1.cloud.databricks.com/api/2.0/fs/files/Volumes/noop_uploads/noop/raw/"
                       + "days__20261102-100000.csv?overwrite=true")
    }

    func testFileURLRefusesNamesThatCouldEscapeThePath() throws {
        let origin = try XCTUnwrap(DatabricksUpload.workspaceOrigin("dbc-1.cloud.databricks.com"))
        XCTAssertNil(DatabricksUpload.fileURL(origin: origin, catalog: "noop/uploads", fileName: "a.csv"))
        XCTAssertNil(DatabricksUpload.fileURL(origin: origin, catalog: "", fileName: "a.csv"))
        XCTAssertNil(DatabricksUpload.fileURL(origin: origin, catalog: "noop_uploads", fileName: "../a.csv"))
        XCTAssertNil(DatabricksUpload.fileURL(origin: origin, catalog: "noop_uploads", fileName: "a b.csv"))
        XCTAssertNil(DatabricksUpload.fileURL(origin: origin, catalog: "noop_uploads", fileName: ".hidden"))
        XCTAssertTrue(DatabricksUpload.isValidCatalog("noop_uploads"))
        XCTAssertFalse(DatabricksUpload.isValidCatalog("catalogò"))
    }

    func testCleanTokenTrimsAndDropsAPastedBearerPrefix() {
        XCTAssertEqual(DatabricksUpload.cleanToken("  dapi123 \n"), "dapi123")
        XCTAssertEqual(DatabricksUpload.cleanToken("Bearer dapi123"), "dapi123")
        XCTAssertNil(DatabricksUpload.cleanToken("   "))
        XCTAssertNil(DatabricksUpload.cleanToken("Bearer "))
    }

    func testRequestIsAPutWithTheBearerTokenAndTheFileAsBody() throws {
        let url = try XCTUnwrap(URL(string: "https://dbc-1.cloud.databricks.com/api/2.0/fs/files/x"))
        let body = Data("day,export_ts\n".utf8)
        let request = DatabricksUpload.request(url: url, token: "dapi123", body: body)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer dapi123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(request.httpBody, body)
    }

    func testStatusCodesMapToWhatTheUserHasToFix() {
        XCTAssertNil(DatabricksUpload.failure(forStatus: 204))
        XCTAssertNil(DatabricksUpload.failure(forStatus: 200))
        XCTAssertEqual(DatabricksUpload.failure(forStatus: 401), .unauthorized(401))
        XCTAssertEqual(DatabricksUpload.failure(forStatus: 403), .unauthorized(403))
        XCTAssertEqual(DatabricksUpload.failure(forStatus: 404), .notFound)
        XCTAssertEqual(DatabricksUpload.failure(forStatus: 500), .http(500))
    }
}
