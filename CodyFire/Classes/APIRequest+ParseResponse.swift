//
//  APIRequest+ParseResponse.swift
//  CodyFire
//
//  Created by Mihael Isaev on 16/10/2018.
//

import Foundation
import Alamofire

extension APIRequest {
    func parseResponse(_ answer: DefaultDataResponse) {
        if cancelled {
            return
        }
        if answer.response != nil {
            handleResponse(answer)
        } else {
            handleResponseError(answer)
        }
    }

    private func handleResponse(_ answer: DefaultDataResponse) {
        guard let response = answer.response else { return }

        log(.info, "Response: \(response.statusCode) on \(method.rawValue.uppercased()) to \(url)")
        log(.debug, "Response data: \(String(describing: response)) on \(method.rawValue.uppercased()) to \(url)")
        if self.retryCondition.contains(StatusCode.from(raw: response.statusCode)) && retriesCounter < retryAttempts {
            log(.info, "retry condition satisfied, starting the request again...")
            retriesCounter += 1
            self.start()
            return
        }

        if successStatusCodes.map({ $0.rawValue }).contains(response.statusCode) {
            handleResponseSuccess(answer)
        } else if StatusCode.unauthorized.rawValue == response.statusCode {
            CodyFire.shared.unauthorizedHandler?()
            if let notAuthorizedCallback = notAuthorizedCallback {
                notAuthorizedCallback()
            } else {
                parseError(.unauthorized, answer.error, answer.data, "Not authorized")
            }
            logError(statusCode: .unauthorized, error: answer.error, data: answer.data)
        } else {
            var errorMessageFromServer = "Something went wrong..."
            if let m = answer.data?.parseJSON()?["message"] as? String {
                errorMessageFromServer = m
            } else if let a = answer.data?.parseJSONAsArray() {
                if a.count == 1, let m = a[0] as? String {
                    errorMessageFromServer = m
                }
            }
            let statusCode = StatusCode.from(response.statusCode)
            parseError(statusCode, answer.error, answer.data, errorMessageFromServer)
            logError(statusCode: statusCode, error: answer.error, data: answer.data)
        }
    }

    private func handleResponseSuccess(_ answer: DefaultDataResponse) {
        var errorRaised = false
        if answer.data != nil {
            errorRaised = handleResponseData(answer)
        } else {
            errorRaised = true
        }
        if errorRaised {
            parseError(._undecodable, answer.error, answer.data, "Something went wrong...")
            logError(statusCode: ._undecodable, error: answer.error, data: answer.data)
        }
    }

    private func handleResponseData(_ answer: DefaultDataResponse) -> Bool {

        guard let response = answer.response, let data = answer.data else { return true }

        var errorRaised = false

        let diff = additionalTimeout - answer.timeline.totalDuration
        let statusCode = StatusCode.from(raw: response.statusCode)
        let headers = answer.response?.allHeaderFields ?? [:]

        if let result = Nothing() as? ResultType {
            delayedResponse(diff) {
                CodyFire.shared.successResponseHandler?(self.host, self.endpoint)
                self.successCallback?(result)
                self.successCallbackExtended?(ExtendedResponse(headers: headers,
                                                               statusCode: statusCode,
                                                               bodyData: data,
                                                               body: result))
                self.flattenSuccessHandler?()
            }
        } else if let result = data as? ResultType {
            delayedResponse(diff) {
                CodyFire.shared.successResponseHandler?(self.host, self.endpoint)
                self.successCallback?(result)
                self.successCallbackExtended?(ExtendedResponse(headers: headers,
                                                               statusCode: statusCode,
                                                               bodyData: data,
                                                               body: result))
                self.flattenSuccessHandler?()
            }
        } else if PrimitiveTypeDecoder.isSupported(ResultType.self) {
            errorRaised = primitiveTypeDecode(answer)
        } else {
            errorRaised = decodeData(answer)
        }
        return errorRaised
    }

    private func primitiveTypeDecode(_ answer: DefaultDataResponse) -> Bool {
        guard let response = answer.response, let data = answer.data else { return true }

        let statusCode = StatusCode.from(raw: response.statusCode)
        let headers = answer.response?.allHeaderFields ?? [:]

        let diff = additionalTimeout - answer.timeline.totalDuration

        guard let value: ResultType = PrimitiveTypeDecoder.decode(data) else {
            log(.error, "🆘 Unable to decode response as \(String(describing: ResultType.self))")
            return true
        }

        delayedResponse(diff) {
            CodyFire.shared.successResponseHandler?(self.host, self.endpoint)
            self.successCallback?(value)
            self.successCallbackExtended?(ExtendedResponse(headers: headers,
                                                           statusCode: statusCode,
                                                           bodyData: data,
                                                           body: value))
            self.flattenSuccessHandler?()
        }

        return false
    }

    private func decodeData(_ answer: DefaultDataResponse) -> Bool {
        guard let response = answer.response, let data = answer.data else { return true }

        let statusCode = StatusCode.from(raw: response.statusCode)
        let headers = answer.response?.allHeaderFields ?? [:]

        let diff = additionalTimeout - answer.timeline.totalDuration
        do {
            let decoder = decoder()
            let decodedResult = try decoder.decode(ResultType.self, from: data)
            delayedResponse(diff) {
                CodyFire.shared.successResponseHandler?(self.host, self.endpoint)
                self.successCallback?(decodedResult)
                self.successCallbackExtended?(ExtendedResponse(headers: headers,
                                                               statusCode: statusCode,
                                                               bodyData: data,
                                                               body: decodedResult))
                self.flattenSuccessHandler?()
            }
        } catch {
            log(.error, "🆘 JSON decoding error: \(error)")
            return true
        }
        return false
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateDecodingStrategy?.jsonDateDecodingStrategy
            ?? CodyFire.shared.dateDecodingStrategy?.jsonDateDecodingStrategy
            ?? DateCodingStrategy.default.jsonDateDecodingStrategy
        return decoder
    }

    private func handleResponseError(_ answer: DefaultDataResponse) {
        guard let err = answer.error as NSError?, err.code == NSURLErrorTimedOut else {
            let errorMessageFromServer = "Something went wrong..."
            let statusCode: StatusCode = ._cannotConnectToHost
            parseError(statusCode, answer.error, answer.data, errorMessageFromServer)
            logError(statusCode: statusCode, error: answer.error, data: answer.data)
            return
        }
        if let timeoutCallback = timeoutCallback {
            timeoutCallback()
        } else {
            parseError(._timedOut, answer.error, answer.data, "Connection timeout")
        }
        logError(statusCode: ._timedOut, error: answer.error, data: answer.data)
        if retriesCounter < retryAttempts && self.retryCondition.allSatisfy([StatusCode.timedOut, StatusCode.requestTimeout].contains) {
            log(.info, "request timed out, trying again...")
            retriesCounter += 1
            self.start()
            return
        }
    }
    
    func delayedResponse(_ diff: TimeInterval, callback: @escaping ()->()) {
        guard diff > 0 else {
            callback()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + diff, execute: callback)
    }
}
