import Foundation
import UIKit
import SwiftUI

import Foundation

let productTypesByCategory: [Category: [String]] = [
    .tops: [
        "Bodysuits",
        "Blouses",
        "Camisoles",
        "Crop Tops",
        "Graphic Tees",
        "Mesh Tops",
        "Off-Shoulder Tops",
        "Polo T-Shirts",
        "Shirts",
        "Tank Tops",
        "Tube Tops",
        "T-Shirts",
        "Turtlenecks"
    ],
    .bottoms: [
        "Jeans",
        "Trousers",
        "Leggings",
        "Joggers",
        "Cargo Pants",
        "Shorts",
        "Skirts",
        "Skorts",
        "Palazzo Pants"
    ],
    .midLayers: [
        "Hoodies",
        "Sweatshirts",
        "Sweaters",
        "Cardigans",
        "Pullovers",
        "Fleece Jackets",
        "Vests",
        "Shrugs",
        "Gilets"
    ],
    .outerwear: [
        "Jackets",
        "Coats",
        "Puffer Jackets",
        "Trench Coats",
        "Blazers",
        "Overcoats",
        "Raincoats"
    ],
    .onePieces: [
        "Dresses",
        "Jumpsuits",
        "Rompers",
        "Playsuits",
        "Dungarees",
        "Overalls"
    ],
    .footwear: [
        "Sneakers",
        "Boots",
        "Heels",
        "Flats",
        "Sandals",
        "Slippers",
        "Loafers",
        "Formal shoes"
    ],
    .accessories: [
        "Hats",
        "Scarves",
        "Gloves",
        "Belts",
        "Handbags",
        "Jewelry",
        "Watches",
        "Sunglasses",
        "Hair Accessories",
        "Ties",
        "Bowties"
    ],
    .innerwear: [
        "Bras",
        "Underwear",
        "Boxers",
        "Thongs",
        "Socks",
        "Thermal Wear",
        "Shapewear",
        "Lingerie"
    ],
    .activewear: [
        "Sports Bras",
        "Active Leggings",
        "Athletic Tops",
        "Track Pants",
        "Athletic Shorts",
        "Active Jackets",
        "Compression Wear",
        "Swimwear",
        "Tennis Dresses"
    ],
    .ethnicWear: [
        "Kurta",
        "Kurti",
        "Sherwani",
        "Nehru Jacket",
        "Dupatta",
        "Saree",
        "Blouse (saree)",
        "Lehenga",
        "Choli",
        "Salwar",
        "Patiala Pants",
        "Anarkali",
        "Angrakha",
        "Dhoti",
        "Lungis",
        "Mundu",
        "Jodhpuri Suit"
    ]
] 