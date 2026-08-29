import Foundation

public enum PluginLLMTemperatureMode: String, Codable, CaseIterable, Sendable {
    case inheritProviderSetting
    case providerDefault
    case custom
}

public enum PluginLLMTemperatureDirective: Sendable, Equatable {
    case inheritProviderSetting
    case providerDefault
    case custom(Double)

    public init(mode: PluginLLMTemperatureMode, value: Double?) {
        switch mode {
        case .inheritProviderSetting:
            self = .inheritProviderSetting
        case .providerDefault:
            self = .providerDefault
        case .custom:
            self = .custom(value ?? 0.3)
        }
    }

    public var mode: PluginLLMTemperatureMode {
        switch self {
        case .inheritProviderSetting:
            return .inheritProviderSetting
        case .providerDefault:
            return .providerDefault
        case .custom:
            return .custom
        }
    }

    public var customValue: Double? {
        switch self {
        case .custom(let value):
            return value
        case .inheritProviderSetting, .providerDefault:
            return nil
        }
    }

    public var resolvedTemperatureValue: Double? {
        switch self {
        case .custom(let value):
            return value
        case .inheritProviderSetting, .providerDefault:
            return nil
        }
    }

    public func resolvedTemperature(applying ruleDirective: PluginLLMTemperatureDirective) -> Double? {
        switch ruleDirective {
        case .inheritProviderSetting:
            return resolvedTemperatureValue
        case .providerDefault:
            return nil
        case .custom(let value):
            return value
        }
    }

    public func clamped(to range: ClosedRange<Double>) -> PluginLLMTemperatureDirective {
        switch self {
        case .custom(let value):
            return .custom(min(max(value, range.lowerBound), range.upperBound))
        case .inheritProviderSetting, .providerDefault:
            return self
        }
    }
}

public protocol LLMTemperatureControllableProvider: LLMProviderPlugin {
    func process(
        systemPrompt: String,
        userText: String,
        model: String?,
        temperatureDirective: PluginLLMTemperatureDirective
    ) async throws -> String
}

/// Optional model-aware catalog used by host UIs. Returning `nil` means the
/// selected backend/model/effort combination does not accept temperature.
/// Kept separate from `LLMTemperatureControllableProvider` for binary
/// compatibility with existing external plugins.
public protocol LLMTemperatureRangeProviding: LLMTemperatureControllableProvider {
    func supportedTemperatureRange(for model: String?, effort: String?) -> ClosedRange<Double>?
}
