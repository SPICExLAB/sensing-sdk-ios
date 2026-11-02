import Foundation

struct TaxonomyNode: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let status: String
}

/// A bundled, read-only copy of the lab's activity taxonomy (`scripts/sync-taxonomy.sh`). The SDK knows nothing about it.
struct Taxonomy: Decodable {
    let version: Int64
    let nodes: [TaxonomyNode]

    static func load() -> Taxonomy {
        guard let url = Bundle.main.url(forResource: "taxonomy", withExtension: "json"), let data = try? Data(contentsOf: url),
              let all = try? JSONDecoder().decode(Taxonomy.self, from: data) else { return Taxonomy(version: 0, nodes: []) }
        return Taxonomy(version: all.version, nodes: all.nodes.filter { $0.status == "active" })
    }

    func roots(matching search: String) -> [(root: String, nodes: [TaxonomyNode])] {
        let found = search.isEmpty ? nodes : nodes.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
        let groups = Dictionary(grouping: found) { $0.id.split(separator: "/").first.map(String.init) ?? $0.id }
        return groups.keys.sorted().map { (root: $0.capitalized, nodes: groups[$0]!.sorted { $0.id < $1.id }) }
    }
}
