DefinitionBlock ("ssdt-npu-cre-hid.aml", "SSDT", 2,
                 "NCZ   ", "NPUCRE  ", 0x00000001)
{
    External (\_SB_.NPU0, DeviceObj)
    External (\_SB_.NPU0.CRE0, DeviceObj)
    External (\_SB_.NPU0.CRE1, DeviceObj)
    External (\_SB_.NPU0.CRE2, DeviceObj)
    Scope (\_SB_.NPU0.CRE0)
    {
        Name (_HID, "CIXH4010")
        Name (_UID, Zero)
        Method (_STA, 0, NotSerialized) { Return (0x0F) }
    }
    Scope (\_SB_.NPU0.CRE1)
    {
        Name (_HID, "CIXH4010")
        Name (_UID, One)
        Method (_STA, 0, NotSerialized) { Return (0x0F) }
    }
    Scope (\_SB_.NPU0.CRE2)
    {
        Name (_HID, "CIXH4010")
        Name (_UID, 0x02)
        Method (_STA, 0, NotSerialized) { Return (0x0F) }
    }
}
