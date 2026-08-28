#MTAudotDraw
#Copyright (C) 2022  CNS-Communications
#
#This program is free software: you can redistribute it and/or modify
#it under the terms of the GNU General Public License as published by
#the Free Software Foundation, either version 3 of the License, or
#(at your option) any later version.
#
#This program is distributed in the hope that it will be useful,
#but WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#GNU General Public License for more details.
#
#You should have received a copy of the GNU General Public License
#along with this program.  If not, see <http://www.gnu.org/licenses/>.

import json
import sys

import textfsm


def read_capture(path):
    with open(path, "rb") as capture_file:
        raw = capture_file.read()

    if raw.startswith((b"\xff\xfe", b"\xfe\xff")):
        return raw.decode("utf-16")
    if raw.startswith(b"\xef\xbb\xbf"):
        return raw.decode("utf-8-sig")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("cp1252", errors="replace")


def main():
    arguments = sys.argv[1:]
    # Opt-in only. Without --objects the output stays a bare list of rows, because the vendor modules
    # that have not been moved onto the parser standard still index those rows by position.
    as_objects = "--objects" in arguments
    positional = [argument for argument in arguments if argument != "--objects"]
    if len(positional) != 2:
        raise ValueError("usage: TextFSM.py [--objects] TEMPLATE CAPTURE")

    template_path, capture_path = positional
    with open(template_path, encoding="utf-8") as template_file:
        table = textfsm.TextFSM(template_file)
        result = table.ParseText(read_capture(capture_path))

    # table.header is the template's Value declaration order - the same order the rows are in. Emitting
    # it lets the caller bind columns by name, so reordering Values in an upstream ntc-template stops
    # being a silent data-corruption vector.
    payload = {"header": table.header, "rows": result} if as_objects else result
    json.dump(payload, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # The PowerShell caller uses the non-zero status as the contract.
        json.dump(
            {"error": type(exc).__name__, "message": str(exc)},
            sys.stderr,
            ensure_ascii=False,
        )
        sys.stderr.write("\n")
        sys.exit(2)
