import Foundation
import SwiftSoup
import KioCore

struct OpenResearchRecord: Sendable, Hashable {
    var title: String
    var url: URL?
    var provider: String
    var authors: String?
    var date: String?
    var venue: String?
    var abstract: String?
    var doi: String?
}

enum OpenResearchSearch {
    static func search(query: String) async throws -> String {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...512).contains(clean.count) else { throw KioFailure.invalidInput("Use a research topic between 3 and 512 characters.") }

        var records: [OpenResearchRecord] = []
        var failures: [String] = []
        do { records.append(contentsOf: try await CrossrefResearchProvider.search(clean)) }
        catch { failures.append("Crossref") }
        try Task.checkCancellation()
        do { records.append(contentsOf: try await EuropePMCResearchProvider.search(clean)) }
        catch { failures.append("Europe PMC") }

        guard failures.count < 2 else {
            throw KioFailure.processing("Scout couldn't reach the free research metadata providers. Try again or give Kio a public URL.")
        }
        return render(records: mergeDuplicates(records), query: clean, partialFailure: failures.first)
    }

    static func render(records: [OpenResearchRecord], query: String, partialFailure: String? = nil) -> String {
        var sections: [String] = []
        for (index, record) in records.prefix(12).enumerated() {
            var lines = ["## \(index + 1). \(markdown(record.title))", "- Provider: \(markdown(record.provider))"]
            if let authors = record.authors, !authors.isEmpty { lines.append("- Authors: \(markdown(authors))") }
            if let date = record.date, !date.isEmpty { lines.append("- Published: \(markdown(date))") }
            if let venue = record.venue, !venue.isEmpty { lines.append("- Publication: \(markdown(venue))") }
            if let doi = record.doi, !doi.isEmpty { lines.append("- DOI: \(markdown(doi))") }
            if let url = record.url, url.scheme == "https", url.host != nil {
                lines.append("- Source: [\(markdown(url.host ?? record.provider))](\(url.absoluteString))")
            }
            if let abstract = record.abstract, !abstract.isEmpty {
                lines.append("\n\(markdown(String(abstract.prefix(900))))")
            }
            sections.append(lines.joined(separator: "\n"))
        }
        let providerNote = partialFailure.map { "\n\nOne provider (\($0)) was unavailable; the results below are partial." } ?? ""
        let body = sections.isEmpty ? "No matching records were returned by Crossref or Europe PMC." : sections.joined(separator: "\n\n")
        return """
        # Open research sources: \(markdown(query))

        Retrieved from the public Crossref and Europe PMC metadata APIs. These are discovery results, not a complete literature review. Metadata and abstracts are provider supplied; verify details at the linked source.\(providerNote)

        \(body)
        """
    }

    private static func mergeDuplicates(_ records: [OpenResearchRecord]) -> [OpenResearchRecord] {
        var merged: [OpenResearchRecord] = []
        var positions: [String: Int] = [:]
        for record in records {
            let key = record.doi?.lowercased() ?? record.title.lowercased().filter { $0.isLetter || $0.isNumber }
            guard let existingIndex = positions[key] else {
                positions[key] = merged.count
                merged.append(record)
                continue
            }
            var existing = merged[existingIndex]
            let providers = Set((existing.provider + ";" + record.provider).split(separator: ";").map(String.init))
            existing.provider = ["Crossref", "Europe PMC"].filter(providers.contains).joined(separator: "; ")
            existing.authors = existing.authors ?? record.authors
            existing.date = existing.date ?? record.date
            existing.venue = existing.venue ?? record.venue
            existing.abstract = existing.abstract ?? record.abstract
            existing.url = existing.url ?? record.url
            existing.doi = existing.doi ?? record.doi
            merged[existingIndex] = existing
        }
        return merged
    }

    static func markdown(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

private enum CrossrefResearchProvider {
    static func search(_ query: String) async throws -> [OpenResearchRecord] {
        var components = URLComponents(string: "https://api.crossref.org/works")!
        components.queryItems = [URLQueryItem(name: "query.bibliographic", value: query), URLQueryItem(name: "rows", value: "6")]
        guard let url = components.url else { throw KioFailure.processing("Scout couldn't form the Crossref request.") }
        let data = try await request(url)
        let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = response?["message"] as? [String: Any]
        let items = message?["items"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let title = (item["title"] as? [String])?.first?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            let doi = item["DOI"] as? String
            let url = doi.flatMap(doiURL)
            let authors = (item["author"] as? [[String: Any]])?.compactMap { author -> String? in
                let name = [author["given"] as? String, author["family"] as? String].compactMap { $0 }.joined(separator: " ")
                return name.isEmpty ? nil : name
            }.joined(separator: ", ")
            return OpenResearchRecord(title: title, url: url, provider: "Crossref", authors: authors?.isEmpty == true ? nil : authors,
                                      date: publicationDate(item, keys: ["published-print", "published-online", "published", "issued"]),
                                      venue: (item["container-title"] as? [String])?.first,
                                      abstract: cleanHTML(item["abstract"] as? String), doi: doi)
        }
    }

    private static func publicationDate(_ item: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let date = item[key] as? [String: Any],
                  let parts = date["date-parts"] as? [[Int]], let first = parts.first, !first.isEmpty else { continue }
            return first.map(String.init).joined(separator: "-")
        }
        return nil
    }

    private static func doiURL(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"(?i)^10\.\d{4,9}/[^\s<>]+$"#, options: .regularExpression) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "doi.org"
        components.path = "/" + value
        return components.url
    }
}

private enum EuropePMCResearchProvider {
    static func search(_ query: String) async throws -> [OpenResearchRecord] {
        var components = URLComponents(string: "https://www.ebi.ac.uk/europepmc/webservices/rest/search")!
        components.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "format", value: "json"),
                                 URLQueryItem(name: "resultType", value: "core"), URLQueryItem(name: "pageSize", value: "6")]
        guard let url = components.url else { throw KioFailure.processing("Scout couldn't form the Europe PMC request.") }
        let data = try await request(url)
        let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let resultList = response?["resultList"] as? [String: Any]
        let items = resultList?["result"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            let source = item["source"] as? String
            let identifier = item["id"] as? String
            let articleURL: URL? = {
                guard let source, let identifier,
                      source.range(of: #"^[A-Za-z0-9_-]{1,16}$"#, options: .regularExpression) != nil,
                      identifier.range(of: #"^[A-Za-z0-9_.-]{1,64}$"#, options: .regularExpression) != nil else { return nil }
                return URL(string: "https://europepmc.org/article/\(source)/\(identifier)")
            }()
            return OpenResearchRecord(title: title, url: articleURL, provider: "Europe PMC",
                                      authors: item["authorString"] as? String,
                                      date: item["firstPublicationDate"] as? String ?? item["pubYear"].map { String(describing: $0) },
                                      venue: item["journalTitle"] as? String,
                                      abstract: cleanHTML(item["abstractText"] as? String), doi: item["doi"] as? String)
        }
    }
}

private func request(_ url: URL) async throws -> Data {
    var request = URLRequest(url: url, timeoutInterval: 18)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Kio local Scout/1.0", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
          http.mimeType?.lowercased() == "application/json", data.count <= 5 * 1_024 * 1_024 else {
        throw KioFailure.processing("A research provider returned an invalid or oversized response.")
    }
    return data
}

private func cleanHTML(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    let cleaned = (try? SwiftSoup.parse(value).text())?.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? value.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    return cleaned.isEmpty ? nil : String(cleaned.prefix(4_000))
}
