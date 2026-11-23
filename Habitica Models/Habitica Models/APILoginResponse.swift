//
//  APILoginResponse.swift
//  Habitica Models
//
//  Provides a local response type for login operations in offline mode.
//

import Foundation

/// A local response type for login operations in standalone/offline mode.
/// Replaces the API client's APILoginResponse when Habitica_API_Client is removed.
public class APILoginResponse: NSObject, LoginResponseProtocol {
    public var id: String?
    public var apiToken: String?
    public var newUser: Bool = false
}