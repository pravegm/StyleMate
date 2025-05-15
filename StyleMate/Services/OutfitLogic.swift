import Foundation
import UIKit

struct Outfit: Equatable, Hashable {
    let top: WardrobeItem
    let bottom: WardrobeItem
    let footwear: WardrobeItem
    let accessory: WardrobeItem?
    let outerwear: WardrobeItem?
}

class OutfitLogic {
    private let items: [WardrobeItem]
    private(set) var history: Set<Outfit> = []
    private let neutrals: Set<String> = ["black", "white", "gray", "beige", "brown", "navy"]
    private let complementary: [String: String] = [
        "red": "green", "green": "red",
        "blue": "orange", "orange": "blue",
        "yellow": "purple", "purple": "yellow"
    ]
    private let analogous: [String: [String]] = [
        "red": ["red-orange", "orange"],
        "orange": ["red", "red-orange", "yellow-orange", "yellow"],
        "yellow": ["yellow-orange", "orange", "yellow-green", "green"],
        "green": ["yellow-green", "yellow", "blue-green", "blue"],
        "blue": ["blue-green", "green", "blue-purple", "purple"],
        "purple": ["blue-purple", "blue", "red-purple", "red"]
        // Add more as needed
    ]
    private let triadic: [[String]] = [
        ["red", "yellow", "blue"],
        ["orange", "green", "purple"]
    ]
    
    init(items: [WardrobeItem]) {
        self.items = items
    }
    
    func generateNextOutfit() -> Outfit? {
        let tops = items.filter { $0.category == .tops }
        let bottoms = items.filter { $0.category == .bottoms }
        let footwears = items.filter { $0.category == .footwear }
        let accessories = items.filter { $0.category == .accessories } + [nil]
        let outerwears = items.filter { $0.category == .seasonalLayering || $0.category == .onePieces } + [nil]
        
        var allCombos: [Outfit] = []
        for top in tops {
            for bottom in bottoms {
                for footwear in footwears {
                    for accessory in accessories {
                        for outerwear in outerwears {
                            let outfit = Outfit(top: top, bottom: bottom, footwear: footwear, accessory: accessory, outerwear: outerwear)
                            allCombos.append(outfit)
                        }
                    }
                }
            }
        }
        // Remove combos with duplicate items
        allCombos = allCombos.filter { Set([$0.top.id, $0.bottom.id, $0.footwear.id, $0.accessory?.id, $0.outerwear?.id].compactMap { $0 }).count == [$0.top, $0.bottom, $0.footwear, $0.accessory, $0.outerwear].compactMap { $0 }.count }
        // Remove combos already in history
        let newCombos = allCombos.filter { !history.contains($0) }
        // Filter by fashion rules
        var validCombos: [Outfit] = []
        for combo in newCombos {
            if isValid(combo) {
                validCombos.append(combo)
            }
        }
        guard let outfit = validCombos.shuffled().first else { return nil }
        history.insert(outfit)
        return outfit
    }
    
    private func isValid(_ outfit: Outfit) -> Bool {
        let items = [outfit.top, outfit.bottom, outfit.footwear, outfit.accessory, outfit.outerwear].compactMap { $0 }
        let allColors = items.flatMap { $0.colors.map { $0.lowercased() } }
        let nonNeutrals = allColors.filter { !neutrals.contains($0) }
        if Set(nonNeutrals).count > 3 {
            return false
        }
        // Pattern rule
        if items.filter({ $0.isPatterned }).count > 1 {
            return false
        }
        // Only one statement piece (complementary or pattern)
        let statementCount = (hasComplementaryPair(nonNeutrals) ? 1 : 0) + (items.filter { $0.isPatterned }.count > 0 ? 1 : 0)
        if statementCount > 1 {
            return false
        }
        // Color harmony
        if hasComplementaryPair(nonNeutrals) {
            // Only one complementary pair, all others must be neutral
            if nonNeutrals.count != 2 {
                return false
            }
            if !allOthersNeutral(allColors, pair: complementaryPair(nonNeutrals)) {
                return false
            }
        } else if isAnalogous(nonNeutrals) || isMonochromatic(nonNeutrals) {
            // OK
        } else if isTriadic(nonNeutrals) {
            if nonNeutrals.count > 3 {
                return false
            }
        } else if nonNeutrals.count > 1 {
            return false // Clashing
        }
        return true
    }
    
    private func comboDescription(_ outfit: Outfit) -> String {
        [outfit.top, outfit.bottom, outfit.footwear, outfit.accessory, outfit.outerwear].compactMap { $0?.product }.joined(separator: ", ")
    }
    
    private func hasComplementaryPair(_ colors: [String]) -> Bool {
        for c1 in colors {
            if let comp = complementary[c1], colors.contains(comp) { return true }
        }
        return false
    }
    private func complementaryPair(_ colors: [String]) -> (String, String)? {
        for c1 in colors {
            if let comp = complementary[c1], colors.contains(comp) { return (c1, comp) }
        }
        return nil
    }
    private func allOthersNeutral(_ colors: [String], pair: (String, String)?) -> Bool {
        guard let pair = pair else { return false }
        for c in colors {
            if c != pair.0 && c != pair.1 && !neutrals.contains(c) { return false }
        }
        return true
    }
    private func isAnalogous(_ colors: [String]) -> Bool {
        guard colors.count > 1 else { return false }
        for c in colors {
            let adj = analogous[c] ?? []
            if !colors.allSatisfy({ $0 == c || adj.contains($0) }) { return false }
        }
        return true
    }
    private func isMonochromatic(_ colors: [String]) -> Bool {
        guard let first = colors.first else { return false }
        return colors.allSatisfy { $0 == first }
    }
    private func isTriadic(_ colors: [String]) -> Bool {
        for triad in triadic {
            if Set(colors).isSubset(of: Set(triad)) && colors.count == Set(colors).count { return true }
        }
        return false
    }
}

extension WardrobeItem {
    var isPatterned: Bool {
        // Simple heuristic: if brand or product contains "pattern" or "print" or "stripe" or "dot" or "floral"
        let patterns = ["pattern", "print", "stripe", "dot", "floral", "plaid", "check", "animal", "camouflage"]
        let text = (brand + " " + product).lowercased()
        return patterns.contains { text.contains($0) }
    }
} 