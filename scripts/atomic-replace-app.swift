import Darwin
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: atomic-replace-app.swift STAGED_APP DESTINATION_APP\n", stderr)
    exit(64)
}

let source = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let destination = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
var sourceInfo = stat()
guard lstat(source.path, &sourceInfo) == 0 else {
    perror("lstat staged app")
    exit(1)
}
var parentInfo = stat()
guard stat(destination.deletingLastPathComponent().path, &parentInfo) == 0 else {
    perror("stat destination parent")
    exit(1)
}
guard sourceInfo.st_dev == parentInfo.st_dev else {
    fputs("staged app and destination must be on the same filesystem\n", stderr)
    exit(64)
}

var destinationInfo = stat()
let destinationExists = lstat(destination.path, &destinationInfo) == 0
if !destinationExists && errno != ENOENT {
    perror("lstat destination")
    exit(1)
}

let flags = destinationExists ? UInt32(RENAME_SWAP) : 0
let result = source.path.withCString { sourcePath in
    destination.path.withCString { destinationPath in
        renameatx_np(AT_FDCWD, sourcePath, AT_FDCWD, destinationPath, flags)
    }
}
guard result == 0 else {
    perror("renameatx_np")
    exit(1)
}

// When replacing, the previous app is now at the staged path. Remove it only
// after the new bundle is atomically visible at the canonical path.
if destinationExists {
    do {
        try FileManager.default.removeItem(at: source)
    } catch {
        fputs("new Kio is installed, but the old bundle at the staging path could not be removed: \(error)\n", stderr)
        exit(2)
    }
}
