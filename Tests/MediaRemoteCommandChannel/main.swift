import Darwin
import Foundation

// Use the default disposition deliberately: an unsafe write must kill this
// isolated regression executable, never the XCTest host or the user's app.
signal(SIGPIPE, SIG_DFL)
if CommandLine.arguments.contains("--unsafe-control") {
    var descriptors: [Int32] = [-1, -1]
    precondition(pipe(&descriptors) == 0)
    close(descriptors[0])
    _ = "refresh\n".withCString { Darwin.write(descriptors[1], $0, 8) }
    fatalError("The unsafe control should terminate with SIGPIPE")
}

do {
    let channel = try MediaRemoteCommandChannel.make()
    try channel.reader.close()
    precondition(!channel.writer.write(line: "refresh"))
    precondition(!channel.writer.write(line: "next"))
    channel.writer.close()
}

do {
    // Exercise Foundation's real stdin duplication with the production channel.
    let channel = try MediaRemoteCommandChannel.make()
    let output = Pipe()
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/cat")
    child.standardInput = channel.reader
    child.standardOutput = output
    try child.run()
    try channel.reader.close()
    precondition(channel.writer.write(line: "refresh"))
    precondition(channel.writer.write(line: "seek 12.500"))
    precondition(!channel.writer.write(line: "next\nprevious"))
    precondition(!channel.writer.write(line: String(repeating: "x", count: 256)))
    channel.writer.close()
    let result = output.fileHandleForReading.readDataToEndOfFile()
    child.waitUntilExit()
    precondition(child.terminationStatus == 0)
    precondition(String(data: result, encoding: .utf8) == "refresh\nseek 12.500\n")
}

do {
    // A non-reading helper cannot make the caller block indefinitely.
    let channel = try MediaRemoteCommandChannel.make()
    var accepted = 0
    while accepted < 100_000 && channel.writer.write(line: String(repeating: "x", count: 255)) {
        accepted += 1
    }
    precondition(accepted > 0 && accepted < 100_000)
    precondition(!channel.writer.write(line: "refresh"))
    try channel.reader.close()
}

for _ in 0..<100 {
    let channel = try MediaRemoteCommandChannel.make()
    let writer = channel.writer
    DispatchQueue.concurrentPerform(iterations: 20) { index in
        if index.isMultiple(of: 3) { writer.close() }
        else { _ = writer.write(line: "refresh") }
    }
    try channel.reader.close()
    precondition(!writer.write(line: "refresh"))
}

print("PASS: broken peer, real child stdin/EOF, bounded backpressure, concurrent close/write")
