# RCU in Zig

**I created this project only for learning Zig and RCUs.**
**This code should not be used in production.**

This project implements a very simple Read-Copy-Update library in Zig and tests
it using a concurrent linked list.

## Usage

```
$ zig build run -Drelease-fast
```

## License

Copyright 2022 Viktor Reusch

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.
