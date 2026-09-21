param([ValidateSet('Snapshot', 'Probe')][string]$Mode = 'Snapshot')
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
function Invoke-EditorTool([string]$Name, [hashtable]$Arguments) {
    $body = @{jsonrpc='2.0'; id=1; method='tools/call'; params=@{name=$Name; arguments=$Arguments}} | ConvertTo-Json -Depth 12
    $response = Invoke-WebRequest -UseBasicParsing -Uri http://127.0.0.1:19192/mcp -Method Post -ContentType 'application/json; charset=utf-8' -Headers @{Accept='application/json, text/event-stream'} -Body ([Text.Encoding]::UTF8.GetBytes($body))
    $reader = [IO.StreamReader]::new($response.RawContentStream, [Text.Encoding]::UTF8)
    try { $result = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    if ($result.result.isError) { throw ($result.result.content.text -join "`n") }
    return ($result.result.content.text -join "`n")
}
$null = Invoke-EditorTool 'vscodeOperator_executeCommand' @{workspacePath=$workspace;command='vscode.open';args=@(@{'$mid'=1;scheme='file';path=('/' + ($workspace -replace '\\','/') + '/lib/ui/app.dart')})}
$lookup = @'
ApexisController? found;
void visit(Element e) {
  if (e is StatefulElement && e.state is _ApexisShellState) found = (e.state as _ApexisShellState).c;
  e.visitChildren(visit);
}
final root = WidgetsBinding.instance.rootElement;
if (root != null) visit(root);
final c = found;
if (c == null) return 'No Apexis controller';
'@
if ($Mode -eq 'Probe') {
    # Deliberately only GET commands. No SET/action, resync, import or export.
    $operation = @'
if (c.demo || !c.ready || c.busy || c.session == null) return 'Real device must be ready and idle';
final s = c.session!;
() async {
  for (final q in <List<int>>[
    [9,1,0x22], [9,1,0x40], [9,1,0], [9,1,0x20], [9,1,0x21],
    [0,1,0x7f], [0,1,0x23], [0,1,0x23,0,3],
    [1,1,0x7f], [1,1,0x20], [1,1,0x22],
    [6,1,0x20], [6,1,0x21], [6,1,0x22], [7,1,0x20],
    [3,1,0], [3,1,0x20], [4,1,0], [4,1,0x21],
    [4,1,0x22], [4,1,0x23], [4,1,0x24], [5,1,0],
    [8,1,0x20,0], [8,1,0x20,1], [0,1,0x32], [0,1,0x36]
  ]) {
    if (!identical(s, c.session) || !c.ready || c.busy) { c.log('AUDIT aborted: session changed or busy'); return; }
    final watch = Stopwatch()..start();
    try {
      final m = await s.command(q[0], q[1], q[2], q.sublist(3));
      c.log('AUDIT GET $q ${watch.elapsedMilliseconds}ms data=${m.data.toList()}');
    } catch (e) { c.log('AUDIT GET $q ERROR $e'); }
  }
  c.log('AUDIT read-only probe complete');
}();
return 'Read-only probe started; call Snapshot to read results';
'@
} else {
    $operation = @'
return {'state':c.state.toString(),'demo':c.demo,'busy':c.busy,'error':c.error,'notice':c.notice,
  'port':c.port?.name,'kind':c.port?.kind,'version':c.identity?.version,'revision':c.revision,
  'selected':c.selected,'units':c.patch?.count,'types':c.types.length,'parameters':c.parameters.length,
  'globals':c.globals.toList(),'patch':c.patch?.bytes.toList(),'logs':c.logs}.toString();
'@
}
$expression = "(() { $lookup $operation })()" -replace '\r?\n', ' '
Invoke-EditorTool 'vscodeOperator_debugEvaluate' @{workspacePath=$workspace;expression=$expression;context='repl'}
