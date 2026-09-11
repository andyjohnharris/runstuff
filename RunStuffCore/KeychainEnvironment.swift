import Foundation
import Security

public enum KeychainEnvironmentError: Error, CustomStringConvertible, Sendable, Equatable {
  case itemNotFound(String)
  case interactionNotAllowed(String)
  case invalidValue(String)
  case keychain(String, OSStatus)

  public var description: String {
    switch self {
    case .itemNotFound(let name):
      return "Keychain item ‘\(name)’ was not found"
    case .interactionNotAllowed(let name):
      return "Keychain access for ‘\(name)’ is not currently allowed"
    case .invalidValue(let name):
      return "Keychain item ‘\(name)’ is not valid UTF-8 text"
    case .keychain(let name, let status):
      return "Could not read Keychain item ‘\(name)’ (OSStatus \(status))"
    }
  }
}

public enum KeychainEnvironment {
  public static let service = "dev.runstuff.environment"

  public static func resolve(_ environment: [String: String]) throws -> [String: String] {
    try resolve(environment, lookup: value)
  }

  static func resolve(
    _ environment: [String: String],
    lookup: (String) throws -> String
  ) throws -> [String: String] {
    var resolved = environment
    for (key, value) in environment {
      guard value.hasPrefix("${keychain:"), value.hasSuffix("}") else { continue }
      let start = value.index(value.startIndex, offsetBy: 11)
      let name = String(value[start..<value.index(before: value.endIndex)])
      guard !name.isEmpty else { continue }
      resolved[key] = try lookup(name)
    }
    return resolved
  }

  private static func value(named name: String) throws -> String {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: name,
      kSecMatchLimit: kSecMatchLimitOne,
      kSecReturnData: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
        throw KeychainEnvironmentError.invalidValue(name)
      }
      return value
    case errSecItemNotFound:
      throw KeychainEnvironmentError.itemNotFound(name)
    case errSecInteractionNotAllowed:
      throw KeychainEnvironmentError.interactionNotAllowed(name)
    default:
      throw KeychainEnvironmentError.keychain(name, status)
    }
  }
}
