import runpy
import subprocess

runpy.run_path("scripts/apply_live_activity_ux_patch.py", run_name="__main__")
# The repository GitHub App token used inside Actions cannot update workflow
# files. Keep that one file unchanged here; the connected GitHub API updates it
# separately after the source patch lands.
subprocess.run(["git", "checkout", "--", ".github/workflows/unsigned-ipa.yml"], check=True)
print("Source-only patch ready")
