import Foundation

/// Whether an active display's EDID codes look like a real panel. Two entries enumerate
/// as active with nothing behind them: the placeholder macOS spawns once the last real
/// display is gone (vendor 'unkn', model 'virt', four-character tags wider than EDID's
/// 16 bits) and the stub a re-enabled record leaves when its hardware is gone (vendor 0,
/// model 0, #91). A PnP vendor id packs three letters A to Z, so it is never 0; the
/// product code can be, and a real monitor reports model 0 (#238).
enum DisplayPanelShape {
    static func hasPanel(vendor: UInt32, model: UInt32) -> Bool {
        vendor != 0 && vendor <= 0xFFFF && model <= 0xFFFF
    }
}
