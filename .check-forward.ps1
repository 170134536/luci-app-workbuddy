# 扫描 ucode 前向引用与重复定义
# 用法: pwsh -File check-forward.ps1 <file>
param([string]$File = 'D:\AI\luci-app-workbuddy\files\usr\share\ucode\workbuddy.uc')

$lines = [IO.File]::ReadAllLines($File, [Text.Encoding]::UTF8)

# 1) 顶层函数定义
$defs = @{}
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(') {
        $n = $Matches[1]
        if ($defs.ContainsKey($n)) {
            Write-Host "  [DUP] $n  行$($defs[$n]) 与 行$($i+1)"
        } else { $defs[$n] = $i + 1 }
    }
}

# 2) 标记模板字符串区间（正确处理一行多个反引号）
$inTpl = $false
$tpl = New-Object bool[] $lines.Count
for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    $ticks = ([regex]::Matches($line, '`')).Count
    if ($inTpl) {
        $tpl[$i] = $true
        if ($ticks % 2 -eq 1) { $inTpl = $false }
    } else {
        if ($ticks % 2 -eq 1) { $tpl[$i] = $true; $inTpl = $true }
    }
}

# 3) 计算每个顶层函数的结束行
$starts = @($defs.Values | Sort-Object)
$endOf = @{}
foreach ($n in $defs.Keys) {
    $e = $lines.Count
    foreach ($s in $starts) { if ($s -gt $defs[$n] -and $s -lt $e) { $e = $s } }
    $endOf[$n] = $e
}

# 4) 找出前向引用
Write-Host ""
Write-Host "=== FORWARD REF CHECK ==="
$risk = 0
foreach ($n in $defs.Keys) {
    $s = $defs[$n] - 1
    $e = $endOf[$n] - 1
    for ($i = $s; $i -lt $e; $i++) {
        if ($tpl[$i]) { continue }
        $line = $lines[$i]
        if ($line -match '^\s*//') { continue }
        foreach ($m in [regex]::Matches($line, '(?<![A-Za-z0-9_.$])([a-z_][A-Za-z0-9_]*)\s*\(')) {
            $callee = $m.Groups[1].Value
            if ($defs.ContainsKey($callee) -and $defs[$callee] -gt $defs[$n]) {
                if ($line -notmatch "F\.$callee\s*\(") {
                    Write-Host ("  [RISK] {0}(行{1}) 调用 {2}(行{3})" -f $n, $defs[$n], $callee, $defs[$callee])
                    $risk++
                }
            }
        }
    }
}

Write-Host ""
if ($risk -eq 0) { Write-Host "OK: no forward reference" } else { Write-Host "FAIL: $risk forward references" }
Write-Host "total top-level functions: $($defs.Count)"

# 5) ucode 不存在的内建方法调用
#
# ucode 的字符串、数组、对象都没有方法：s.replace() / a.push() / o.has()
# 都会在运行期抛 "left-hand side is not a function"。
# 这些错误只在被调到的那一行才暴露，静态扫一遍能提前拦住。
# 注意：模板字符串里的 JS 是给浏览器执行的，必须跳过。
Write-Host ""
Write-Host "=== METHOD CALL CHECK ==="
$badMethods = @('push', 'replace', 'includes', 'indexOf', 'slice', 'splice',
    'concat', 'filter', 'map', 'forEach', 'trim', 'split', 'join',
    'toLowerCase', 'toUpperCase', 'startsWith', 'endsWith', 'has',
    'substring', 'charAt', 'toString', 'repeat', 'padStart', 'sort', 'pop', 'shift')
$mrisk = 0
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($tpl[$i]) { continue }
    $line = $lines[$i]
    if ($line -match '^\s*//') { continue }
    foreach ($m in [regex]::Matches($line, '\.([A-Za-z_][A-Za-z0-9_]*)\s*\(')) {
        $meth = $m.Groups[1].Value
        if ($badMethods -contains $meth) {
            Write-Host ("  [RISK] line {0}: .{1}() -- ucode has no such method" -f ($i + 1), $meth)
            Write-Host ("         {0}" -f $line.Trim())
            $mrisk++
        }
    }
}
Write-Host ""
if ($mrisk -eq 0) { Write-Host "OK: no bad method calls" } else { Write-Host "FAIL: $mrisk bad method calls" }

# 6) 模板字符串里的 HTML onclick 转义检查
#
# 管理页整体是一个反引号模板字符串，里面嵌了生成 HTML 的 JS。
# 要在 JS 字符串里输出「反斜杠 + 单引号」，源码必须写「两个反斜杠 + 单引号」。
# 只写一个反斜杠会被模板字符串吃掉，渲染成两个连续单引号，
# 使整段 script 抛 SyntaxError —— 管理页永远停在「加载中…」。
# 判据：模板字符串区间内，onclick 属性里的引号转义不足即为坏行。
Write-Host ""
Write-Host "=== TEMPLATE ESCAPE CHECK ==="
$BS = [string][char]92
$SQ = [string][char]39
$SINGLE = $BS + $SQ
$DOUBLE = $BS + $BS + $SQ
$erisk = 0
for ($i = 0; $i -lt $lines.Count; $i++) {
    if (-not $tpl[$i]) { continue }
    $line = $lines[$i]
    if ([string]::IsNullOrEmpty($line)) { continue }
    if (-not $line.Contains('onclick="')) { continue }
    if (-not $line.Contains($SINGLE)) { continue }
    # 把已正确的双反斜杠形态先挖掉，剩下的单反斜杠就是漏网的
    $probe = $line.Replace($DOUBLE, '')
    if ($probe.Contains($SINGLE)) {
        Write-Host ("  [RISK] line {0}: onclick 引号转义不足" -f ($i + 1))
        Write-Host ("         {0}" -f $line.Trim())
        $erisk++
    }
}
Write-Host ""
if ($erisk -eq 0) { Write-Host "OK: no template escape issues" } else { Write-Host "FAIL: $erisk template escape issues" }
