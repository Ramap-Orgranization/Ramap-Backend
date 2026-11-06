import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

DIRECTORY = Path(__file__).resolve().parent

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, DIRECTORY / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

provision = load('r2_provision_test', 'provision.py')
import sys
sys.path.insert(0, str(DIRECTORY))
deploy_worker = load('r2_worker_deploy_test', 'deploy_worker.py')
configure_cache = load('r2_cache_setup_test', 'configure_cache.py')
migrate = load('r2_migrate_test', 'migrate.py')

class R2ToolsTest(unittest.TestCase):
    def setUp(self):
        self.config = {'r2_account_id': 'a' * 32, 'r2_public_bucket': 'ramap-test-public', 'r2_private_bucket': 'ramap-test-private'}

    def test_domain_can_be_added_later_but_private_and_public_must_differ(self):
        self.assertEqual(provision.validate(self.config), self.config)
        with self.assertRaises(ValueError):
            provision.validate({**self.config, 'r2_private_bucket': self.config['r2_public_bucket']})

    def test_retired_cleanup_accepts_only_an_explicit_bucket_list(self):
        allowed = {**self.config, 'legacy_gcs_cleanup_buckets': ['old-private', 'old-public']}
        self.assertEqual(provision.validate(allowed), allowed)
        for buckets in ['old-private', ['https://example.com'], ['old;other'], [None]]:
            with self.assertRaises(ValueError):
                provision.validate({**self.config, 'legacy_gcs_cleanup_buckets': buckets})

    def test_owned_domain_is_required_for_cdn(self):
        for domain in ['http://images.example.com', 'https://public.r2.dev', 'https://images.example.com/path', 'https://user:secret@images.example.com']:
            with self.assertRaises(ValueError):
                provision.validate({**self.config, 'r2_public_base_url': domain, 'cloudflare_zone_id': 'b' * 32})

    def test_worker_address_needs_no_owned_domain_or_zone(self):
        config = {**self.config, 'public_worker_name': 'ramap-images', 'r2_public_base_url': 'https://ramap-images.account.workers.dev'}
        self.assertEqual(provision.validate(config), config)
        for base in ['https://other.account.workers.dev', 'https://account.workers.dev', 'https://ramap-images.account.workers.dev/path']:
            with self.assertRaises(ValueError):
                provision.validate({**config, 'r2_public_base_url': base})

    def test_worker_has_only_public_bucket_binding_and_no_secrets(self):
        settings = deploy_worker.worker_configuration(self.config)
        self.assertEqual(settings['r2_buckets'], [{'binding': 'PUBLIC_IMAGES', 'bucket_name': self.config['r2_public_bucket']}])
        self.assertTrue(settings['workers_dev'])
        self.assertNotIn('routes', settings)
        self.assertEqual(settings['vars'], {'EDGE_CACHE_ENABLED': 'false'})
        self.assertTrue(settings['cache']['enabled'])
        enabled = deploy_worker.worker_configuration({**self.config, 'public_cache_enabled': True})
        self.assertTrue(enabled['cache']['enabled'])
        self.assertFalse(enabled['cache']['cross_version_cache'])
        self.assertEqual(enabled['vars'], {'EDGE_CACHE_ENABLED': 'true'})
        self.assertNotIn(self.config['r2_private_bucket'], json.dumps(settings))

    def test_private_bucket_with_public_domain_is_rejected(self):
        def api(config, method, path, body=None):
            if path == '':
                return {'buckets': [{'name': self.config['r2_public_bucket']}, {'name': self.config['r2_private_bucket']}]}
            if path.endswith('custom'):
                return {'domains': [{'domain': 'private.example.com', 'enabled': True}]} if 'private' in path else {'domains': []}
            return {}
        with patch.object(provision, 'cloudflare', api), self.assertRaises(ValueError):
            provision.provision(self.config)

    def test_cache_setup_reuses_existing_secret_without_putting_it_in_arguments_or_files(self):
        secret = 'existing-secret-fixture-' * 3
        calls = []
        def command(args, **options):
            calls.append((args, options.get('input')))
            self.assertNotIn(secret, ' '.join(args))
            if 'secret' in args and 'put' in args:
                self.assertNotIn(secret, Path(args[args.index('--config') + 1]).read_text())
            output = secret if args[1:4] == ['secrets', 'versions', 'access'] else ''
            return subprocess.CompletedProcess(args, 0, stdout=output, stderr='')
        with patch.object(configure_cache.subprocess, 'run', command), patch.object(Path, 'exists', return_value=True):
            result = configure_cache.configure(self.config)
        self.assertTrue(result['reused'])
        self.assertFalse(any(args[1:4] == ['secrets', 'versions', 'add'] for args, _ in calls))
        self.assertEqual(calls[-1][1], secret)
        self.assertNotIn(secret, json.dumps(result))

    def test_cache_setup_generates_one_value_for_both_providers(self):
        secret = 'a' * 64
        inputs = []
        def command(args, **options):
            if options.get('input') is not None:
                inputs.append(options['input'])
            code = 1 if args[1:3] == ['secrets', 'describe'] else 0
            return subprocess.CompletedProcess(args, code, stdout='', stderr='')
        with patch.object(configure_cache.subprocess, 'run', command), patch.object(Path, 'exists', return_value=True), patch.object(configure_cache.secrets, 'token_hex', return_value=secret):
            result = configure_cache.configure(self.config)
        self.assertFalse(result['reused'])
        self.assertEqual(inputs, [secret, secret])

    def test_provision_requests_standard_apac_and_disables_development_domain(self):
        calls = []
        def api(config, method, path, body=None):
            calls.append((method, path, body))
            if method == 'GET' and not path:
                return {'buckets': []}
            return {'domains': []}
        with patch.object(provision, 'cloudflare', api):
            provision.provision(self.config)
        created = [c[2] for c in calls if c[0] == 'POST']
        self.assertEqual(len(created), 2)
        self.assertTrue(all(c['locationHint'] == 'apac' and c['storageClass'] == 'Standard' for c in created))
        self.assertEqual(len([c for c in calls if c[0] == 'PUT' and c[2] == {'enabled': False}]), 2)

    def test_copy_uses_supabase_source_and_never_removes_original(self):
        tool = object.__new__(migrate.Migration)
        tool.config = {'media_api_url': 'https://media.example.com'}
        tool.key = 'test'
        requests = []
        tool.request = lambda method, url, data, headers: requests.append((method, url, json.loads(data))) or b'{"copied":true}'
        source = {'provider': 'supabase', 'bucket': 'profile-avatars', 'path': 'a.jpg', 'updated_at': '2026-11-03T00:00:00Z'}
        row = {'migration_needed': True, 'migration_reason': 'current_reference', 'bucket': 'profile-avatars', 'path': 'a.jpg', 'locations': [], 'legacy_updated_at': '2026-11-03T00:00:00Z'}
        self.assertTrue(tool.copy(row)['copied'])
        self.assertEqual(requests[0][0], 'POST')
        self.assertTrue(requests[0][1].endswith('/internal/v2/backfill'))
        self.assertEqual(requests[0][2]['source'], source)
        self.assertEqual(len(requests), 1)

    def test_unused_images_are_skipped_before_storage_requests(self):
        tool = object.__new__(migrate.Migration)
        tool.request = lambda *args: self.fail('An excluded image was transferred')
        row = {'migration_needed': False, 'migration_reason': 'ended_event'}
        self.assertTrue(tool.copy(row)['skipped'])
        with self.assertRaises(ValueError):
            migrate.needed({'locations': []})

    def test_only_verified_live_r2_copies_are_complete(self):
        for verified, deleted, expected in [(True, False, True), (False, False, False), (True, True, False)]:
            self.assertEqual(migrate.copied({'locations': [{'provider': 'r2', 'verified': verified, 'deleted': deleted}]}), expected)

if __name__ == '__main__':
    unittest.main()
