//
//  TrialFileUploader.swift
//  arvos
//
//  Created by Moritz Kolvenbach on 11.09.26.
//

import Foundation

final class TrialFileUploader {
    enum UploadError: LocalizedError {
        case invaldiResponse
        case serverRejected(Int, String)
        
        var errorDescription: String? {
            switch self {
            case .invaldiResponse:
                return "Invalid response from server"
            case let .serverRejected(status, body):
                return "Upload failed with HTTP: \(status): \(body)"
            }
        }
    }
    
    private let session: URLSession
    
    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        session = URLSession(configuration: configuration)
    }
    
    func upload(
        completedVideo: CompletedLocalVideo,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let files = [completedVideo.videoURL, completedVideo.sidecarURL]
        upload(files: files, index: 0, baseURL: completedVideo.uploadBaseURL, completion: completion)
    }
    
    private func upload(
        files: [URL],
        index: Int,
        baseURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard index < files.count else {
            // keep failed uploads for retry, remove lcoal files after both PUTs succeed.
            try? FileManager.default.removeItem(
                at: files[0].deletingLastPathComponent()
            )
            completion(.success(()))
            return
        }
        let fileURL = files[index]
        let destination = baseURL.appendingPathComponent(
            fileURL.lastPathComponent
        )
        var request = URLRequest(url: destination)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        
        session.uploadTask(with: request, fromFile: fileURL) {
            [weak self] data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            
            guard let response = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    completion(.failure(UploadError.invaldiResponse))
                }
                return
            }
            
            guard 200..<300 ~= response.statusCode else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                DispatchQueue.main.async {
                    completion(.failure(UploadError.serverRejected(response.statusCode, body)))
                }
                return
            }
            
            self?.upload(
                files: files,
                index: index + 1,
                baseURL: baseURL,
                completion: completion
            )
        }.resume()
    }
}
