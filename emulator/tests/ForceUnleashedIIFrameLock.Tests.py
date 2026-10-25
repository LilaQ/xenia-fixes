"""Check the patch against the owner's decoded base image, without shipping it.

Usage: python3.11+ ForceUnleashedIIFrameLock.Tests.py /private/default.pe
This verifies version-specific code locations and the paired config, not FPS.
"""
from pathlib import Path
import struct
import sys
import tomllib

root = Path(__file__).resolve().parents[1]
patch = tomllib.loads((root / "game-patches/4C4107F2 - The Force Unleashed II 60FPS.patch.toml").read_text())
assert patch["title_id"] == "4C4107F2"
assert patch["hash"] == "0C35DD8FCC1766CD"
entry, = patch["patch"]
assert entry["is_enabled"]
write, = entry["be32"]
assert write == {"address": 0x8223626C, "value": 0x3960003C}

image = Path(sys.argv[1]).read_bytes()
def word(address):
    return struct.unpack_from(">I", image, address - 0x82000000)[0]

# Original load, integer conversion, engine-field store and timing consumer.
# Reject a different executable before using the version-specific address.
for address, instruction in {
    0x8223626C: 0x81640158, 0x82236278: 0x7D6A07B4,
    0x82236280: 0xF9410050, 0x82236284: 0xC8010050,
    0x82236288: 0xFDA0069C, 0x82236290: 0xFD806818,
    0x82236294: 0xD1830244, 0x822398E0: 0xC03C0244,
}.items():
    assert word(address) == instruction, f"Wrong base image at {address:08X}"

config = tomllib.loads((root / "files/force-unleashed-ii-edge-644ba68-overrides.toml").read_text())
assert config["GPU"]["render_target_path"] == "performance"
assert config["GPU"]["occlusion_query"] == "strict"
assert config["GPU"]["readback_resolve"] is True
assert config["GPU"]["guest_display_refresh_cap"] is False
assert config["GPU"]["framerate_limit"] == 60
assert config["General"]["time_scalar"] == 1
assert config["General"]["apply_patches"] is True
print("PASS: TFU2 base-code locations, single frame-lock write and paired rendering/timing configuration.")
