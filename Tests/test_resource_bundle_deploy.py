"""Run only extracted resource functions in temp dirs; never run the installer."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
INSTALLER=ROOT/'cli/install.sh'
BODY=INSTALLER.read_text().split('# BEGIN RESOURCE_BUNDLE_FUNCTIONS\n',1)[1].split('# END RESOURCE_BUNDLE_FUNCTIONS',1)[0]


class ResourceBundleDeployment(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='tc-resource-deploy-');self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.source=self.root/'source bundle';self.source.mkdir()
        self.destination=self.root/'installed app/TokenClock_TokenClock.bundle'
        (self.source/'data.txt').write_bytes(b'first resources\n')
        (self.source/'empty dir').mkdir()

    def run_body(self,suffix,extra=''):
        code='set -uo pipefail\nDEPLOYED_ANYTHING=0\nRESOURCE_BUNDLE_CHANGED=0\n'+BODY+'\n'+extra+'\n'+suffix
        return subprocess.run(['/bin/bash','-c',code,'resource-test',str(self.source),str(self.destination)],
            capture_output=True,text=True,cwd=self.root,env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','TMPDIR':str(self.root)},timeout=30)

    def deploy(self,extra=''):
        return self.run_body('if deploy_resource_bundle "$1" "$2"; then result=0; else result=$?; fi\n'
            'printf "RESULT:%s DEPLOYED:%s CHANGED:%s\\n" "$result" "$DEPLOYED_ANYTHING" "$RESOURCE_BUNDLE_CHANGED"\nexit "$result"',extra)

    def install_old(self):
        self.destination.parent.mkdir(parents=True,exist_ok=True)
        shutil.copytree(self.source,self.destination)
        (self.destination/'data.txt').write_bytes(b'old resources\n')

    def assert_no_staging(self):
        self.assertEqual(list(self.destination.parent.glob('.tokenclock-resources.*')),[])

    def test_first_install_and_resource_only_update_set_deployed(self):
        result=self.deploy();self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('DEPLOYED:1 CHANGED:1',result.stdout)
        self.assertEqual((self.destination/'data.txt').read_bytes(),b'first resources\n')
        binary=self.destination.parent/'TokenClock';binary.write_bytes(b'unchanged main executable fixture')
        old_binary=binary.read_bytes()
        (self.source/'data.txt').write_bytes(b'worker-only update\n')
        result=self.deploy();self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('DEPLOYED:1 CHANGED:1',result.stdout)
        self.assertEqual(binary.read_bytes(),old_binary)
        self.assertEqual((self.destination/'data.txt').read_bytes(),b'worker-only update\n');self.assert_no_staging()

    def test_equal_contents_ignore_mtimes_and_skip_copy(self):
        self.destination.parent.mkdir(parents=True);shutil.copytree(self.source,self.destination)
        old_inode=self.destination.stat().st_ino
        os.utime(self.source/'data.txt',(1_000_000,1_000_000));os.utime(self.source,(2_000_000,2_000_000))
        result=self.deploy('cp() { printf "unexpected copy\\n" >&2; return 91; }')
        self.assertEqual(result.returncode,0,result.stderr);self.assertIn('DEPLOYED:0 CHANGED:0',result.stdout)
        self.assertEqual(self.destination.stat().st_ino,old_inode);self.assert_no_staging()

    def test_partial_copy_failure_preserves_old_bundle(self):
        self.install_old();before=(self.destination/'data.txt').read_bytes()
        result=self.deploy('cp() { mkdir -p "$3"; printf partial > "$3/partial.txt"; return 72; }')
        self.assertNotEqual(result.returncode,0);self.assertIn('DEPLOYED:0 CHANGED:0',result.stdout)
        self.assertEqual((self.destination/'data.txt').read_bytes(),before);self.assert_no_staging()

    def test_changed_staging_content_never_replaces_previous_bundle(self):
        self.install_old()
        result=self.deploy('cp() { /bin/cp "$@" || return; printf corrupted > "$3/data.txt"; }')
        self.assertNotEqual(result.returncode,0);self.assertIn('DEPLOYED:0 CHANGED:0',result.stdout)
        self.assertEqual((self.destination/'data.txt').read_bytes(),b'old resources\n');self.assert_no_staging()

    def test_activation_failure_restores_previous_directory(self):
        self.install_old()
        result=self.deploy('mv() { case "$1" in */bundle) return 73;; esac; /bin/mv "$@"; }')
        self.assertNotEqual(result.returncode,0);self.assertIn('DEPLOYED:0 CHANGED:0',result.stdout)
        self.assertEqual((self.destination/'data.txt').read_bytes(),b'old resources\n');self.assert_no_staging()

    def test_hash_tracks_names_symlink_targets_and_executable_bits(self):
        unusual=self.source/'line\nbreak ; $(not-run).txt';unusual.write_bytes(b'literal content\x00with NUL')
        (self.source/'alias').symlink_to('data.txt')
        result=self.deploy();self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.destination/unusual.name).read_bytes(),unusual.read_bytes())
        (self.source/'alias').unlink();(self.source/'alias').symlink_to(unusual.name)
        result=self.deploy();self.assertEqual(result.returncode,0,result.stderr);self.assertIn('CHANGED:1',result.stdout)
        self.assertEqual(os.readlink(self.destination/'alias'),unusual.name)
        (self.source/'data.txt').chmod(0o755)
        result=self.deploy();self.assertEqual(result.returncode,0,result.stderr);self.assertIn('CHANGED:1',result.stdout)
        self.assertTrue(os.access(self.destination/'data.txt',os.X_OK))
        unusual.rename(self.source/'renamed.txt')
        result=self.deploy();self.assertEqual(result.returncode,0,result.stderr);self.assertIn('CHANGED:1',result.stdout)

    def test_hash_does_not_read_symlink_target_contents(self):
        outside=self.root/'outside fixture';outside.write_bytes(b'outside first')
        (self.source/'alias').symlink_to(outside)
        first=self.run_body('resource_bundle_hash "$1"');self.assertEqual(first.returncode,0,first.stderr)
        outside.write_bytes(b'outside changed but not part of resource tree')
        second=self.run_body('resource_bundle_hash "$1"');self.assertEqual(second.returncode,0,second.stderr)
        self.assertEqual(first.stdout,second.stdout)

    def test_non_directory_or_symlink_resource_root_is_rejected_without_touching_destination(self):
        self.install_old();actual=self.root/'actual source';self.source.rename(actual);self.source.symlink_to(actual,target_is_directory=True)
        result=self.deploy();self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.destination/'data.txt').read_bytes(),b'old resources\n');self.assert_no_staging()


if __name__=='__main__':unittest.main()
