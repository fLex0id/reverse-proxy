import ipaddress, sys
try:
    if ipaddress.ip_address(sys.argv[1]).version != 4: raise ValueError()
except ValueError:
    sys.exit("Укажите IPv4 российского DNS (или yandex)")
