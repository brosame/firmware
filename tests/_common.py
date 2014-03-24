import time
import os
import re
import unittest
import paramiko
from zope.testbrowser.browser import Browser


_IP_PREFIX = "172.16.137."


class Host(object):

    ap_regex = r"^ap([0-9]\.[0-9]+)$"

    def __init__(self, name, ip_num):
        self.name = name
        self.ip = "%s%d" % (_IP_PREFIX, ip_num)
        self._url_prefix = "http://%s/" % self.ip

    def get_browser(self, url=None):
        if url is None:
            url = self.get_url()
        elif url.startswith("/"):
            url = self.get_url(url)
        try:
            browser = Browser()
            # verwende deutschsprachiges Interface
            browser.addHeader("Accept-Language", "de-DE,de")
            browser.open(url)
            return browser
        except IOError:
            return None

    def get_opennet_ap_id(self):
        ap_match = re.search(self.ap_regex, self.name)
        return ap_match.groups()[0] if ap_match else None

    def get_url(self, path=""):
        return "%s/%s" % (self._url_prefix.rstrip("/"), path.lstrip("/"))

    def __str__(self):
        return "%s<%s>" % (self.name, self.ip)


def get_hosts():
        ip_prefix = "172.16.137."
        for name, ip_num in (("ap1.201", 11), ("ap1.202", 12), ("ap1.203", 13),
                ("client_user", 14), ("client_wifidog", 15)):
            yield Host(name, ip_num)


class TextResult(object):

    def __init__(self, file_obj):
        self.lines = []
        while True:
            line = file_obj.readline()
            if not line:
                break
            # Zeilenumbruch entfernen
            self.lines.append(line[:-1])

    def is_empty(self):
        return len(self.lines) == 0

    def contains(self, token):
        for line in self.lines:
            if token in line:
                return True
        return False

    def contains_line(self, line):
        return line in self.lines

    def __contains__(self, text):
        return self.contains(text)

    def __str__(self):
        return os.linesep.join(self.lines)


class ExecResult(object):

    def __init__(self, exit_code, stdout_obj, stderr_obj):
        self.exit_code = exit_code
        self.success = self.exit_code == 0
        self.stdout = TextResult(stdout_obj)
        self.stderr = TextResult(stderr_obj)

    def __contains__(self, text):
        return text in self.stdout


class OpennetTest(unittest.TestCase):
    """ Basisklasse fuer alle Opennet-relevanten Tests
    Hier koennen spezifische Einstellungen (Passwort) und Funktionen
    untergebracht werden.
    """

    username = "root"
    default_password = "admin"
    new_password = "oni-admin"
    test_dir = os.path.abspath(os.path.dirname(os.path.realpath(__file__)))
    auth_token_regex = r"(/luci/;stok=[0-9a-z]+/)"

    def _is_auth_needed(self, browser):
        return "Benutzernamen und Passwort" in browser.contents

    def _login(self, browser, passwords=None, force=False):
        if passwords is None:
            passwords = (self.default_password, self.new_password)
        if not self._is_auth_needed(browser):
            if not force:
                return True
            else:
                browser.open("/cgi-bin/luci/admin/logout")
        for password in passwords:
            form = browser.getForm()
            form.getControl(name="username").value = self.username
            form.getControl(name="password").value = password
            form.getControl(label="Anmelden").click()
            if not self._is_auth_needed(browser):
                return True
        else:
            return False

    def open_link(self, browser, url):
        """ Oeffne eine neue URL unter Beibehaltung des luci-auth-Tokens
        Beispiel-URL: http://172.16.137.11/cgi-bin/luci/;stok=1c50965d5a99cc47c507cc4e5cd207ed/opennet/opennet_2/
        """
        token_match = re.search(self.auth_token_regex, browser.url)
        if token_match:
            token = token_match.groups()[0]
            url.replace("/luci/", token)
        browser.open(url)

    def _get_ssh_key_filename(self, public=True):
        suffix = "pub" if public else "sec"
        return os.path.join(self.test_dir, "ssh_key.%s" % suffix)

    def _get_ssh_pub_key(self):
        keyfile_secret = self._get_ssh_key_filename(public=False)
        keyfile_public = self._get_ssh_key_filename(public=True)
        if not os.path.exists(keyfile_secret) or not os.path.exists(keyfile_public):
            key = paramiko.RSAKey.generate(4096)
            key.write_private_key_file(keyfile_secret)
            file(keyfile_public, "w").write("ssh-rsa " + key.get_base64())
        return file(keyfile_public, "r").read()

    def _get_ssh_client(self, auto_create=True):
        if not getattr(self, "host", None):
            # immer abbrechen, falls host noch nicht gesetzt wurde
            return None
        if not getattr(self, "_ssh_clients", None):
            self._ssh_clients = {}
        if self.host.ip in self._ssh_clients:
            return self._ssh_clients[self.host.ip]
        if not auto_create:
            return None
        client = paramiko.SSHClient()
        sec_keyfile = self._get_ssh_key_filename(public=False)
        # die Schluessel der virtualisierten APs sind uns egal
        class IgnoreKeysPolicy(paramiko.MissingHostKeyPolicy):
            missing_host_key = lambda *args: True
        client.set_missing_host_key_policy(IgnoreKeysPolicy())
        # Verbindungsaufbau
        client.connect(self.host.ip, username=self.username,
                key_filename=[sec_keyfile], allow_agent=False,
                look_for_keys=False)
        self._ssh_clients[self.host.ip] = client
        return client

    def _execute(self, command, input_data=None):
        client = self._get_ssh_client()
        transport = client.get_transport()
        channel = transport.open_channel("session")
        channel.exec_command(command)
        while input_data:
            count = channel.send(input_data)
            if count > 0:
                input_data = input_data[count:]
        while not channel.exit_status_ready():
            time.sleep(0.1)
        return ExecResult(channel.recv_exit_status(), channel.makefile(),
                channel.makefile_stderr())

    def _get_ips(self, ip_version=4, with_mask=False):
        regexes = {
                4: r" inet ([0-9.]{7,15}/[0-9]+) ",
                6: r" inet ([0-9a-f:]{7,15}/[0-9]+) ",
        }
        result = self._execute("ip -%d addr show" % ip_version)
        if not result.success:
            return []
        #ips = re.findall(regexes[ip_version], " ".join(result.stdout.lines).lower())
        ips = re.findall(regexes[ip_version], str(result.stdout).lower())
        if ips:
            if with_mask:
                return ips
            else:
                return [ip.split("/")[0] for ip in ips]
        else:
            return []

    def _has_ip(self, ip):
        with_mask = "/" in ip
        ip_version = 4 if "." in ip else 6
        return ip in self._get_ips(ip_version=ip_version, with_mask=with_mask)

    def tearDown(self):
        client = self._get_ssh_client(auto_create=False)
        if client:
            client.close()


class AllHostsTest(OpennetTest):
    """ Wenige Tests sind fuer alle Hosts gleichermassen geeignet """

    hosts = tuple(get_hosts())


class OneHostTest(OpennetTest):
    """ Die meisten Tests sind host-spezifisch """

    def __init__(self, host, *args, **kwargs):
        self.host = host
        super(BaseTest, self).__init__(*args, **kwargs)

