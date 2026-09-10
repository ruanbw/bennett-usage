import Foundation

public struct ModelPricing: Codable, Sendable, Equatable {
    public let modelPattern: String
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    public let cacheReadPerMillion: Double
    public let cacheWritePerMillion: Double

    public init(
        modelPattern: String,
        inputPerMillion: Double,
        outputPerMillion: Double,
        cacheReadPerMillion: Double = 0.0,
        cacheWritePerMillion: Double = 0.0
    ) {
        self.modelPattern = modelPattern
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
    }
}
