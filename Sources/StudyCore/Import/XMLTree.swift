import Foundation

/// Tiny DOM built on XMLParser. Element names keep their namespace prefix ("a:t", "p:sp").
public final class XNode {
    public let name: String
    public var attributes: [String: String]
    public var children: [XNode] = []
    public var text: String = ""
    weak var parent: XNode?

    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }

    public func all(_ name: String) -> [XNode] {
        var out: [XNode] = []
        func walk(_ n: XNode) { for c in n.children { if c.name == name { out.append(c) }; walk(c) } }
        walk(self)
        return out
    }
    public func first(_ name: String) -> XNode? {
        for c in children { if c.name == name { return c }; if let f = c.first(name) { return f } }
        return nil
    }
    public func child(_ name: String) -> XNode? { children.first { $0.name == name } }
    public func childrenNamed(_ name: String) -> [XNode] { children.filter { $0.name == name } }
    public subscript(attr: String) -> String? { attributes[attr] }

    /// Concatenated text of all descendants with the given text element name (e.g. "a:t").
    public func texts(_ element: String) -> String { all(element).map(\.text).joined() }
}

public enum XMLTree {
    public static func parse(_ data: Data) -> XNode? {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() else { return delegate.root }
        return delegate.root
    }

    final class Builder: NSObject, XMLParserDelegate {
        var root: XNode?
        var stack: [XNode] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let n = XNode(name: name, attributes: attributes)
            if let top = stack.last { n.parent = top; top.children.append(n) } else { root = n }
            stack.append(n)
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    }

    /// Parses an OPC relationships part into id → target.
    public static func relationships(_ data: Data?) -> [String: (target: String, type: String)] {
        guard let data, let root = parse(data) else { return [:] }
        var out: [String: (String, String)] = [:]
        for r in root.all("Relationship") {
            if let id = r["Id"], let target = r["Target"] { out[id] = (target, r["Type"] ?? "") }
        }
        return out
    }
}
