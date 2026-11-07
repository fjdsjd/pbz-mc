"""Large first registration and bounded MC-only recovery; isolated files, no PBZ process."""
from pathlib import Path
import hashlib
import json
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "build/lua-check"))
from lupa.lua54 import LuaRuntime

with tempfile.TemporaryDirectory() as tmp:
    (Path(tmp) / "pbzmc-data/player-store").mkdir(parents=True)
    runtime = LuaRuntime(unpack_returned_tuples=True)
    host = {"PBZGameSystem": {"chapter": 2, "precise": 9007199254740993},
            "quests": [0] * 110000, "padding": "中" * 500000}
    baseline = json.dumps(host, ensure_ascii=False, separators=(",", ":"))
    id_ = "2e989fd4-0a2c-4f51-9f04-683077c13cfb"
    counts = {"identity": 0, "checkpoint": 0, "uuid": 0}

    def raw():
        return json.dumps(host, ensure_ascii=False, separators=(",", ":"))

    def sha(value):
        return hashlib.sha256(value.encode()).hexdigest()

    def summary():
        marker = host.get("PBZMC_CampaignIdentity")
        value = {"needs_registration": True, "root_sha256": sha(raw()), "root_bytes": len(raw().encode())}
        if marker:
            value["campaign_id"] = marker["campaign_id"]
        return json.dumps(value)

    def uuid():
        counts["uuid"] += 1
        return id_, None

    def identity(path, before, identity_id):
        assert path == "test-subsystem" and before == sha(raw()) and "PBZMC_CampaignIdentity" not in host
        counts["identity"] += 1
        host["PBZMC_CampaignIdentity"] = dict(owner="pbzmc", schema="campaign-identity-v1", campaign_id=identity_id)
        return json.dumps(dict(campaign_id=identity_id, before_sha256=before, after_sha256=sha(raw()))), None

    def checkpoint(path, before, identity_id, digest):
        assert path == "test-subsystem" and before == sha(raw())
        assert host["PBZMC_CampaignIdentity"]["campaign_id"] == identity_id
        counts["checkpoint"] += 1
        host["PBZMC_Checkpoint"] = dict(owner="pbzmc", schema="campaign-checkpoint-v1", campaign_id=identity_id, checkpoint=digest)
        return json.dumps(dict(campaign_id=identity_id, checkpoint=digest, before_sha256=before, after_sha256=sha(raw()))), None

    globals_ = runtime.globals()
    globals_.PBZMC_NewCampaignId = uuid
    globals_.PBZMC_CreateCampaignIdentity = identity
    globals_.PBZMC_PutCampaignCheckpoint = checkpoint
    globals_.source = ROOT.as_posix()
    globals_.base = Path(tmp).as_posix() + "/pbzmc-data/"
    globals_.raw_backup = raw()
    globals_.native_summary = summary()
    runtime.execute(r'''
package.path=source..'/src/?.lua;'..source..'/third_party/dkjson/?.lua;'..package.path
IsInGameThread=function()return true end
local state=require('storage.state');local decode=state.decode
-- Rejecting large Lua decodes proves this path uses only small native proofs,
-- not a second full JSON tree or lossy conversion of PBZ's 64-bit numbers.
state.decode=function(text)assert(#text<65536,'full native root decoded in Lua');return decode(text)end
PBZMC_ReadOrdinaryJson=function()error('redundant full native read')end
local reg=require('host.pbz.campaign_registration')
receipt=reg.ensure(base,'test-subsystem',state.decode(native_summary),nil,raw_backup)
assert(receipt.campaign_id and receipt.checkpoint)
''')
    assert counts == {"identity": 1, "checkpoint": 1, "uuid": 1}
    saved_files = {str(p.relative_to(tmp)): p.read_bytes() for p in Path(tmp).rglob("*") if p.is_file()}
    backups = [v for k, v in saved_files.items() if k.endswith("-native-before.json")]
    assert backups == [baseline.encode()]
    # Power interruption after the identity was stored but before its anchor.
    host.pop("PBZMC_Checkpoint")
    globals_.native_summary = summary()
    runtime.execute("require('host.pbz.campaign_registration').ensure(base,'test-subsystem',require('storage.state').decode(native_summary))")
    assert counts == {"identity": 1, "checkpoint": 2, "uuid": 1}
    assert saved_files == {str(p.relative_to(tmp)): p.read_bytes() for p in Path(tmp).rglob("*") if p.is_file()}
    host.pop("PBZMC_CampaignIdentity")
    host.pop("PBZMC_Checkpoint")
    assert raw() == baseline
    print(f"PASS: {len(baseline.encode()):,}-byte old chapter root, 64-bit number preserved; zero full-root Lua decodes; one backup and none on bootstrap recovery")
