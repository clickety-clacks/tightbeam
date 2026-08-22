import Foundation
import JavaScriptCore

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: identity_apply_jsc_runner.swift <normalizer.js> <base64-source>...\n".utf8))
    exit(2)
}

let normalizerSource = try String(contentsOfFile: arguments[1], encoding: .utf8)

for encoded in arguments.dropFirst(2) {
    guard let bytes = Data(base64Encoded: encoded),
          let fixture = String(data: bytes, encoding: .utf8),
          let context = JSContext()
    else {
        print("{\"kind\":\"unsupported\",\"type\":\"inspection-failure\"}")
        continue
    }

    var capturedException: JSValue?
    context.exceptionHandler = { _, exception in capturedException = exception }
    context.evaluateScript(normalizerSource)

    capturedException = nil
    let returned = context.evaluateScript("(function () {\n\(fixture)\n}())")
    let value = capturedException ?? returned
    capturedException = nil

    let api = context.objectForKeyedSubscript("TightbeamFailureNormalizer")
    let normalize = api?.objectForKeyedSubscript("normalize")
    let result = normalize?.call(withArguments: value.map { [$0] } ?? [JSValue(undefinedIn: context)!])

    if capturedException != nil || result == nil {
        print("{\"kind\":\"unsupported\",\"type\":\"inspection-failure\"}")
    } else {
        print(result!.toString()!)
    }
}
