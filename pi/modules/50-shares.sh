# 50-shares — Samba over $NOOK_DATA/files, for the devices that cannot do SFTP.
#
# Off unless --shares. Your own laptop does not need this: it gets the same
# directory over SSH with nothing extra running here.

[[ $NOOK_SHARES == 1 ]] || return 0

dpkg -s samba >/dev/null 2>&1 || apt-get install -y -qq samba

MARK_BEGIN="# >>> nook"
MARK_END="# <<< nook"
CONF=/etc/samba/smb.conf

# Bound to the tailnet interface. Samba on a home LAN is a share; Samba on every
# interface a travelling Pi meets is an invitation.
block=$(cat <<CONF_BLOCK
$MARK_BEGIN
[global]
	bind interfaces only = yes
	interfaces = lo tailscale0
	server min protocol = SMB3
	server smb encrypt = required

[files]
	path = $NOOK_DATA/files
	browseable = yes
	read only = no
	valid users = $NOOK_USER
	force user = $NOOK_USER
$MARK_END
CONF_BLOCK
)

python3 - "$CONF" "$MARK_BEGIN" "$MARK_END" <<PY
import pathlib, re, sys
path, begin, end = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
block = """$block
"""
text = path.read_text() if path.exists() else ""
if begin in text and end in text:
    text = re.sub(re.escape(begin) + r".*?" + re.escape(end) + r"\n?", lambda m: block, text, flags=re.S)
else:
    text = text.rstrip() + "\n\n" + block
path.write_text(text)
PY

systemctl enable --now smbd >/dev/null
systemctl restart smbd

# Samba keeps its own password database — the Unix password is not enough.
pdbedit -L 2>/dev/null | grep -q "^$NOOK_USER:" || {
  warn "no Samba password for $NOOK_USER yet — set one with: sudo smbpasswd -a $NOOK_USER"
}
note "smb://$NOOK_NAME/files"
