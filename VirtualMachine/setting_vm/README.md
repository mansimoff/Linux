Базовая настройка Виртуальной машины линукс после её создания

Новая VM
   │
   ├── root SSH
   │
   ▼
Ansible
   │
   ├── update/upgrade
   ├── создать пользователя
   ├── sudo
   ├── установить SSH key
   ├── SSH → :222
   ├── запретить root login
   ├── nftables
   └── sshguard
   │
   ▼
Готовый сервер
   │
   └── SSH → <username>@server:222
