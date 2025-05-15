import Foundation
import UIKit
import SwiftUI

import Foundation

let productTypesByCategory: [Category: [String]] = [
  .tops:             ["T-shirts","Shirts","Polo shirts","Tank tops","Blouses","Crop tops","Sweaters","Sweatshirts","Hoodies","Jackets","Blazers","Cardigans","Vests","Kurtas","Shackets"],
  .bottoms:          ["Jeans","Trousers","Chinos","Shorts","Skirts","Leggings","Joggers","Track pants","Cargo pants","Dhotis","Salwars"],
  .onePieces:        ["Dresses","Jumpsuits","Rompers","Sarees","Gowns","Overalls"],
  .footwear:         ["Sneakers","Formal shoes","Loafers","Boots","Sandals","Flip flops","Heels","Flats","Slippers","Mojaris/Juttis"],
  .accessories:      ["Watches","Sunglasses","Spectacles","Belts","Hats","Caps","Scarves","Necklaces","Earrings","Bracelets","Bangles","Rings","Ties","Cufflinks","Backpacks","Handbags","Clutches","Wallets"],
  .innerwearSleepwear:["Undergarments","Bras","Boxers/Briefs","Night suits","Loungewear","Slips","Thermals"],
  .ethnicOccasionwear:["Sherwanis","Lehenga cholis","Anarkalis","Nehru jackets","Dupattas","Kurta sets","Blouse (ethnic)","Dhoti sets"],
  .seasonalLayering: ["Raincoats","Windcheaters","Overcoats","Thermal inners","Gloves","Beanies"]
] 