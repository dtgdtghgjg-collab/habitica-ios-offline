//
//  APICheckEmailResponse.swift
//  Habitica Models
//
//  Provides a local response type for email validation in offline mode.
//

import Foundation

/// A local response type for email validation operations in standalone/offline mode.
/// Replaces the API client's APICheckEmailResponse when Habitica_API_Client is removed.
public class APICheckEmailResponse: NSObject, CheckEmailResponse {
    public var email: String?
    public var valid: Bool = false
    public var error: String?
}