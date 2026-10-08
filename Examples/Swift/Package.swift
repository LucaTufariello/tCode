// swift-tools-version: 6.4
import PackageDescription
let package = Package(name:"TCodeSample",platforms:[.macOS("27.0")],products:[.executable(name:"Sample",targets:["Sample"])],targets:[.target(name:"SampleCore"),.executableTarget(name:"Sample",dependencies:["SampleCore"]),.testTarget(name:"SampleTests",dependencies:["SampleCore"])])
