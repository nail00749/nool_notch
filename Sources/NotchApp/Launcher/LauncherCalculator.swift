import Foundation

enum LauncherCalculator {
    private static let maximumInputLength = 256
    private static let maximumTokenCount = 128
    private static let maximumNestingDepth = 32

    static func evaluate(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed.count <= maximumInputLength else { return nil }

        do {
            var parser = try Parser(
                input: trimmed,
                maximumTokenCount: maximumTokenCount,
                maximumNestingDepth: maximumNestingDepth
            )
            let value = try parser.parse()
            guard value.isFinite else { return nil }
            return format(value)
        } catch {
            return nil
        }
    }

    private static func format(_ value: Double) -> String {
        if value.rounded() == value, value >= Double(Int64.min), value < Double(Int64.max) {
            return String(Int64(value))
        }
        return String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private struct Parser {
        private enum Token: Equatable {
            case number(Double)
            case plus
            case minus
            case multiply
            case divide
            case power
            case leftParen
            case rightParen
        }

        private var tokens: [Token]
        private var index = 0
        private let maximumNestingDepth: Int

        init(input: String, maximumTokenCount: Int, maximumNestingDepth: Int) throws {
            self.tokens = try Self.tokenize(input, maximumTokenCount: maximumTokenCount)
            self.maximumNestingDepth = maximumNestingDepth
        }

        mutating func parse() throws -> Double {
            let result = try parseAddition(depth: 0)
            guard index == tokens.count else { throw ParseError.malformed }
            return result
        }

        private mutating func parseAddition(depth: Int) throws -> Double {
            var value = try parseMultiplication(depth: depth)
            while let token = current, token == .plus || token == .minus {
                index += 1
                let rhs = try parseMultiplication(depth: depth)
                value = token == .plus ? value + rhs : value - rhs
                try validate(value)
            }
            return value
        }

        private mutating func parseMultiplication(depth: Int) throws -> Double {
            var value = try parseUnary(depth: depth)
            while let token = current, token == .multiply || token == .divide {
                index += 1
                let rhs = try parseUnary(depth: depth)
                value = token == .multiply ? value * rhs : value / rhs
                try validate(value)
            }
            return value
        }

        private mutating func parseUnary(depth: Int) throws -> Double {
            if current == .plus {
                index += 1
                return try parseUnary(depth: depth)
            }
            if current == .minus {
                index += 1
                let value = -(try parseUnary(depth: depth))
                try validate(value)
                return value
            }
            return try parsePower(depth: depth)
        }

        private mutating func parsePower(depth: Int) throws -> Double {
            var value = try parsePrimary(depth: depth)
            if current == .power {
                index += 1
                let rhs = try parseUnary(depth: depth)
                value = Foundation.pow(value, rhs)
                try validate(value)
            }
            return value
        }

        private mutating func parsePrimary(depth: Int) throws -> Double {
            guard depth <= maximumNestingDepth else { throw ParseError.tooComplex }
            guard let token = current else { throw ParseError.malformed }
            switch token {
            case .number(let value):
                index += 1
                return value
            case .leftParen:
                index += 1
                let value = try parseAddition(depth: depth + 1)
                guard current == .rightParen else { throw ParseError.malformed }
                index += 1
                return value
            default:
                throw ParseError.malformed
            }
        }

        private var current: Token? {
            guard index < tokens.count else { return nil }
            return tokens[index]
        }

        private func validate(_ value: Double) throws {
            guard value.isFinite else { throw ParseError.nonFinite }
        }

        private static func tokenize(_ input: String, maximumTokenCount: Int) throws -> [Token] {
            var tokens: [Token] = []
            var index = input.startIndex

            func append(_ token: Token) throws {
                guard tokens.count < maximumTokenCount else { throw ParseError.tooComplex }
                tokens.append(token)
            }

            while index < input.endIndex {
                let character = input[index]
                if character.isWhitespace {
                    input.formIndex(after: &index)
                    continue
                }

                switch character {
                case "+": try append(.plus)
                case "-": try append(.minus)
                case "*": try append(.multiply)
                case "/": try append(.divide)
                case "^": try append(.power)
                case "(": try append(.leftParen)
                case ")": try append(.rightParen)
                default:
                    guard character.isNumber || character == "." else { throw ParseError.malformed }
                    let start = index
                    var decimalPoints = 0
                    var digits = 0
                    while index < input.endIndex {
                        let numberCharacter = input[index]
                        if numberCharacter.isNumber {
                            digits += 1
                            input.formIndex(after: &index)
                        } else if numberCharacter == "." {
                            decimalPoints += 1
                            guard decimalPoints == 1 else { throw ParseError.malformed }
                            input.formIndex(after: &index)
                        } else {
                            break
                        }
                    }
                    guard digits > 0, let value = Double(input[start..<index]), value.isFinite else {
                        throw ParseError.malformed
                    }
                    try append(.number(value))
                    continue
                }
                input.formIndex(after: &index)
            }

            guard tokens.isEmpty == false else { throw ParseError.malformed }
            return tokens
        }
    }

    private enum ParseError: Error {
        case malformed
        case nonFinite
        case tooComplex
    }
}
