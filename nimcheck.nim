import std/[strutils, options, os]
import regex
import chronos, chronos/asyncproc
import stew/[byteutils]
import chronicles
import utils

type
  CheckStacktrace* = object
    file*: string
    line*: int
    column*: int
    msg*: string

  CheckResult* = object
    file*: string
    line*: int
    column*: int
    msg*: string
    severity*: string
    stacktrace*: seq[CheckStacktrace]

proc isFromLib(path: string, libPath: Option[string]): bool =
  if libPath.isNone:
    return false
  result = expandFilename(path).startsWith(expandFilename(libPath.get))

proc parseCheckResults(
    lines: seq[string], libPath: Option[string], excludeLib: bool
): seq[CheckResult] =
  result = @[]
  var
    messageText = ""
    stacktrace: seq[CheckStacktrace]
    lastFile, lastLineStr, lastCharStr: string
    m: RegexMatch2

  let dotsPattern = re2"^\.+$"
  let errorPattern = re2"^([^(]+)\((\d+),\s*(\d+)\)\s*(\w+):\s*(.*)$"

  for line in lines:
    let line = line.strip()

    if line.startsWith("Hint: used config file") or line == "" or
        line.match(dotsPattern):
      continue

    if not find(line, errorPattern, m):
      if messageText.len < 1024:
        messageText &= "\n" & line
    else:
      try:
        let
          file = line[m.captures[0]]
          lineStr = line[m.captures[1]]
          charStr = line[m.captures[2]]
          severity = line[m.captures[3]]
          msg = line[m.captures[4]]

        if excludeLib and isFromLib(file, libPath):
          continue

        let
          lineNum = parseInt(lineStr)
          colNum = parseInt(charStr)

        result.add(CheckResult(
          file: file,
          line: lineNum,
          column: colNum,
          msg: msg,
          severity: severity,
          stacktrace: @[],
        ))

      except Exception as e:
        error "Error processing line", line = line, msg = e.msg
        continue

  if messageText.len > 0 and result.len > 0:
    result[^1].msg &= "\n" & messageText

proc nimCheck*(
    filePath: string,
    nimPath: string,
    libPath: Option[string],
    excludeLib: bool,
): Future[seq[CheckResult]] {.async.} =
  debug "nimCheck", filePath = filePath, nimPath = nimPath, excludeLib = excludeLib
  let isNimble = filePath.endsWith(".nimble")
  let isNimScript = filePath.endsWith(".nims") or isNimble
  var extraArgs = newSeq[string]()
  if isNimScript:
    extraArgs.add("--import: system/nimscript")
  if isNimble:
    extraArgs.add("--include: " & getNimScriptAPITemplatePath())
  let process = await startProcess(
    nimPath,
    arguments = @["check", "--listFullPaths"] & extraArgs & @[filePath],
    options = {UsePath},
    stderrHandle = AsyncProcess.Pipe,
    stdoutHandle = AsyncProcess.Pipe,
  )
  try:
    let res = await process.waitForExit(15.seconds)
    # debug "nimCheck exit", res = res
    var output = ""
    if res == 0: #Nim check return 0 if there are no errors but we still need to check for hints and warnings
      output = string.fromBytes(process.stdoutStream.read().await)
    else:
      output = string.fromBytes(process.stderrStream.read().await)

    let lines = output.splitLines()
    parseCheckResults(lines, libPath, excludeLib)

  finally:
    await shutdownChildProcess(process)
