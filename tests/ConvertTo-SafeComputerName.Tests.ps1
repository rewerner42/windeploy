#requires -Version 5.1
<#  Pester-Tests für ConvertTo-SafeComputerName (§5.9).
    Ausführen:  Invoke-Pester .\tests\ConvertTo-SafeComputerName.Tests.ps1  #>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\payload\lib\Deploy.Common.psm1') -Force
}

Describe 'ConvertTo-SafeComputerName' {

    It 'bildet einen normalen Namen aus Präfix + Seriennummer' {
        $n = ConvertTo-SafeComputerName -Serial '5CG1234ABC' -Prefix 'MUS-'
        $n | Should -Be 'MUS-5CG1234ABC'
    }

    It 'hält die 15-Zeichen-NetBIOS-Grenze ein' {
        $n = ConvertTo-SafeComputerName -Serial '0123456789ABCDEF' -Prefix 'MUS-'
        $n.Length | Should -BeLessOrEqual 15
    }

    It 'entfernt ungültige Zeichen und Leerzeichen' {
        $n = ConvertTo-SafeComputerName -Serial 'PF-0X 12/34' -Prefix 'AB'
        $n | Should -Match '^[A-Z0-9-]+$'
        $n | Should -Not -Match '[ /]'
    }

    It 'nutzt den Fallback bei Platzhalter-Seriennummer' {
        $n = ConvertTo-SafeComputerName -Serial 'To Be Filled By O.E.M.' -Prefix 'MUS-' -FallbackSuffix 'AABBCCDDEEFF'
        $n | Should -Match '^MUS-'
        $n.Length | Should -BeLessOrEqual 15
    }

    It 'nutzt den Fallback bei "Default string"' {
        $n = ConvertTo-SafeComputerName -Serial 'Default string' -Prefix 'PC' -FallbackSuffix 'DEADBEEF'
        $n | Should -Match '^PC'
    }

    It 'nutzt den Fallback bei nur Nullen' {
        $n = ConvertTo-SafeComputerName -Serial '0000000000' -Prefix 'PC' -FallbackSuffix 'ABCDEF'
        $n | Should -Be 'PCABCDEF'
    }

    It 'wirft ohne Fallback bei Platzhalter' {
        { ConvertTo-SafeComputerName -Serial '' -Prefix 'PC' } | Should -Throw
    }

    It 'erzeugt keinen rein numerischen Namen' {
        $n = ConvertTo-SafeComputerName -Serial '2345' -Prefix '1'
        $n | Should -Not -Match '^[0-9]+$'
    }

    It 'behält den eindeutigen Serien-Endteil bei zu langem Wert' {
        $n = ConvertTo-SafeComputerName -Serial 'ABCDEFGHIJKLMNOP' -Prefix 'X-'
        # Budget = 15 - 2 = 13; Endteil erwartet
        $n | Should -Be 'X-DEFGHIJKLMNOP'
    }

    It 'hat keinen führenden/schließenden Bindestrich' {
        $n = ConvertTo-SafeComputerName -Serial '---123ABC---' -Prefix 'PC'
        $n | Should -Not -Match '(^-|-$)'
    }
}
