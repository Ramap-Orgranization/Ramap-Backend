"""Trusted photo tooling: Supabase control requests without exposing server credentials."""
import json
import subprocess
import urllib.error
import urllib.request

PUBLIC = {'shop-profile-images', 'event-images', 'menu-images'}


class MediaService:
    def __init__(self, config):
        self.config = config
        self.root = 'https://' + config['supabase_ref'] + '.supabase.co'
        result = subprocess.run(['supabase', 'projects', 'api-keys', '--project-ref', config['supabase_ref'], '--output', 'json'],
                                capture_output=True, text=True, check=True)
        rows = json.loads(result.stdout)
        if not isinstance(rows, list):
            rows = rows.get('api_keys', rows.get('keys', []))
        self.key = next(row['api_key'] for row in rows if row.get('name') == 'service_role')

    def request(self, method, url, data=None, headers=None):
        request = urllib.request.Request(url, method=method, data=data,
                                         headers={'User-Agent': 'RamapMediaTool/1.0', **(headers or {})})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            raise RuntimeError('Media request failed (HTTP ' + str(error.code) + ')') from None

    def rpc(self, name, body):
        payload = self.request('POST', self.root + '/rest/v1/rpc/' + name, json.dumps(body).encode(),
                               {'apikey': self.key, 'Authorization': 'Bearer ' + self.key, 'Content-Type': 'application/json'})
        return json.loads(payload) if payload else None
