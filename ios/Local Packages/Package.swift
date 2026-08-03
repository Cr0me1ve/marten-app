// swift-tools-version: 5.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
     name: "Marten Packages",
     platforms: [
        // Minimum platform version
         .iOS(.v13)
     ],
     products: [
         .library(
             name: "MartenCore",
             targets: ["MartenCore"]),
     ],
     dependencies: [
         // No dependencies
     ],
     targets: [
        .binaryTarget(
            name: "MartenCore",
            path: "../Frameworks/MartenCore.xcframework"
        )
     ]
 )
