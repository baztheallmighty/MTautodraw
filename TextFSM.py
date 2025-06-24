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

import sys
import textfsm

template = sys.argv[1]
input_file = sys.argv[2]

try:
    with open(template) as f, open(input_file, errors='ignore') as input:
        re_table = textfsm.TextFSM(f)
        header = re_table.header
        result = re_table.ParseText(input.read())
except:
    print("An exception occurred")
    print(sys.exc_info())
else:
    print(result)