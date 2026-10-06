function New-QAOpsUlid {
    <# Generates a canonical ULID using 48-bit Unix milliseconds plus 80 cryptographic random bits; PowerShell 5.1 compatible. #>
    [CmdletBinding()]
    param()
    $epoch = [DateTime]::SpecifyKind([DateTime]'1970-01-01T00:00:00Z',[DateTimeKind]::Utc)
    $ms = [Int64]([Math]::Floor(([DateTime]::UtcNow - $epoch).TotalMilliseconds))
    $bytes = New-Object byte[] 16
    for ($i=5; $i -ge 0; $i--) { $bytes[$i] = [byte]($ms -band 0xff); $ms = [Math]::Floor($ms / 256) }
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random = New-Object byte[] 10; $rng.GetBytes($random); [Array]::Copy($random,0,$bytes,6,10) } finally { $rng.Dispose() }
    $alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
    $value = [System.Numerics.BigInteger]::Zero
    $be = New-Object byte[] 17
    for ($i=0; $i -lt 16; $i++) { $be[$i] = $bytes[15-$i] }
    $value = New-Object System.Numerics.BigInteger (, $be)
    $chars = New-Object char[] 26
    for ($i=25; $i -ge 0; $i--) { $idx = [int]($value % 32); $chars[$i] = $alphabet[$idx]; $value = [System.Numerics.BigInteger]::Divide($value, 32) }
    -join $chars
}
