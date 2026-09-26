# kvm-create-vm

Ansible-плейбук для быстрого создания тестовых VM на локальной машине
KVM/libvirt: установка с диска-ISO → готовая VM с вашим пользователем и SSH-доступом по ключу, без единого клика в virt-manager.

```
create_vm.yml   — плейбук
inventory.yml   — localhost
vars.yml        — параметры конкретной VM 
```

## Как это работает

Установка идёт с обычного установочного ISO через
**Kickstart**:
1. Создаётся пустой qcow2-диск нужного размера.
2. Генерируется `ks.cfg` (пользователь, хеш пароля, SSH-ключ, автопартиционирование,
   hostname, минимальный набор пакетов + `openssh-server`).
3. `ks.cfg` упаковывается в маленький ISO с меткой **`OEMDRV`** — Anaconda
   сама находит диск с такой меткой и берёт kickstart оттуда, без
   необходимости поднимать HTTP/FTP-сервер или указывать `inst.ks=` вручную
   через сеть.
4. `virt-install --location <iso> --wait -1` грузит инсталлятор напрямую
   (kernel/initrd) и **блокируется до полного завершения установки** —
   включая финальный `reboot` из kickstart в уже установленную систему.
   Это принципиально: без `--wait` virt-install выходит сразу после старта
   установки, некому обработать событие reboot от инсталлятора — и VM
   просто гаснет вместо того, чтобы остаться работающей.
5. Технический cdrom с kickstart извлекается и файл ISO удаляется — он
   нужен был только на время установки.
6. VM получает IP по DHCP, IP заносится в `/etc/hosts` под именем VM —
   дальше можно `ssh <username>@<vm_name>` вместо IP.

Перед стартом самой установки плейбук:
- проверяет/поднимает libvirt-сеть (`virsh net-start`, если не активна);
- печатает итоговую конфигурацию VM и **спрашивает подтверждение** (yes/no) — без этого дальше не идёт.
## Поддерживаемые ОС

Работает для любого дистрибутива на базе **Anaconda-инсталлятора** — то есть всей RHEL-семьи:

| ОС | Статус |
|---|---|
| Rocky Linux 8 / 9 / 10 | ✅ основной сценарий |
| AlmaLinux 8 / 9 / 10 | ✅ (та же Anaconda, `os_variant` подобрать под дистрибутив) |
| CentOS Stream 9 / 10 | ✅ |
| RHEL 8 / 9 / 10 | ✅ |
| RHEL/CentOS/Rocky 7 | ⚠️ частично — директива `sshkey` в kickstart появилась в pykickstart для 8.4+; для 7-й ветки нужно заменить на `%post`-скрипт с записью ключа в `~/.ssh/authorized_keys` вручную |

**Не поддерживается "из коробки":**

| ОС | Почему |
|---|---|
| Debian | другой инсталлятор (debian-installer), конфиг через **preseed**, не kickstart; нет автообнаружения по метке `OEMDRV` |
| Ubuntu (20.04+) | инсталлятор Subiquity, конфиг через **autoinstall** (cloud-init-подобный YAML), передаётся через `ds=nocloud` в boot-параметрах, а не через OEMDRV |
| Cloud-образы (qcow2) | это отдельный сценарий — нет инсталлятора, разворачивается через cloud-init, а не kickstart. См. раздел "Идеи для развития" |

Обязательное требование к образу: **полный DVD-ISO**, не `boot.iso`
(netinstall) — kickstart не указывает внешний `url`-репозиторий, пакеты берутся с самого ISO.

## Требования

На хосте:

```bash
# RHEL-семейство
sudo dnf install -y qemu-kvm libvirt virt-install genisoimage

# Debian/Ubuntu-хост (гипервизор), сами ВМ всё равно RHEL-семейства
sudo apt install -y qemu-kvm libvirt-daemon-system virtinst genisoimage
```

Пользователь — в группе `libvirt`, либо запуск с `-K` (спросит sudo-пароль).

## Использование

```bash
# отредактировать vars.yml: имя, cpu, ram, диск, путь до ISO, ssh-ключ, хеш пароля
openssl passwd -6 'мойпароль'  # → вставить в vm_password_hash

ansible-playbook -i inventory.yml create_vm.yml -K
```

`vars.yml` подключается плейбуком автоматически (`vars_files`), флаг
`-e @vars.yml` не нужен. Разово переопределить что-то можно через `-e`:

```bash
ansible-playbook -i inventory.yml create_vm.yml -K -e vm_name=other-test
```

### Создание нескольких VM параллельно

Можно запускать в разных терминалах одновременно — единственное условие: разный `vm_name` (файлы дисков/ISO именуются по нему, коллизий не будет).
Держите отдельный `vars.yml` на каждый сценарий (`vars-web.yml`, `vars-db.yml` и т.п.) и указывайте нужный через `-e @vars-web.yml`.

### Удаление VM

```bash
sudo virsh destroy test-vm
sudo virsh undefine test-vm --nvram --remove-all-storage
sudo sed -i '/\stest-rocky9$/d' /etc/hosts
```

## Переменные (vars.yml)

| Переменная | Обязательна | По умолчанию | Описание |
|---|---|---|---|
| `vm_name` | да | — | Имя VM в libvirt и hostname внутри гостя |
| `vm_memory_mb` | да | — | ОЗУ, МБ |
| `vm_vcpus` | да | — | Число vCPU |
| `vm_disk_size` | да | — | Размер диска (`20G`) |
| `iso_path` | да | — | Путь к полному DVD-ISO |
| `ssh_pub_key` | да | — | Публичный SSH-ключ |
| `vm_password_hash` | да | — | Хеш пароля (`openssl passwd -6`) |
| `vm_user` | нет | `admin` | Пользователь внутри VM, `wheel` + `NOPASSWD` sudo |
| `vm_network` | нет | `default` | Имя libvirt-сети |
| `os_variant` | нет | `generic` | `virt-install --os-variant`, см. `osinfo-query os` |
| `images_dir` | нет | `/var/lib/libvirt/images` | Каталог для дисков и ISO |
| `workdir` | нет | `~/tmp/kvm-create-vm` | Временная директория для `ks.cfg` |
| `timezone` | нет | `UTC` | Таймзона гостя |

## Известные ограничения

- Root внутри VM залочен (`rootpw --lock`) — доступ только через sudo-пользователя. Если нужен root по SSH — уберите строку и добавьте
  `rootpw --iscrypted <hash>`.
- `%packages` жёстко использует `@^minimal-environment` (имя группы специфично для comps.xml RHEL-семейства).
- Плейбук ожидает libvirt-сеть по имени, а не создаёт свою — сеть
  `default` должна существовать хотя бы в неактивном состоянии
  (`virsh net-define`/`net-autostart` — не автоматизировано).
- IPv4-only парсинг адреса из `virsh domifaddr`.

## Идеи для развития

**Поддержка Debian/Ubuntu** — основная нереализованная функциональность:
- Debian: генерировать `preseed.cfg` вместо `ks.cfg`, паковать на тот же
  принцип secondary-диска (d-i умеет читать preseed с локального устройства
  через `preseed/file=`), либо через `file=/cdrom/preseed.cfg` при boot
  с `--extra-args`.
- Ubuntu 20.04+: генерировать `user-data`/`meta-data` в формате
  **autoinstall** (тот же синтаксис, что у cloud-init, но для установщика
  Subiquity), паковать в ISO с меткой `cidata` (не `OEMDRV`!) и передавать
  `--extra-args "autoinstall ds=nocloud;"`.
- Абстрагировать генерацию unattended-конфига через переменную
  `os_family: rhel|debian|ubuntu`, выбирающую нужный шаблон и boot-параметры,
  оставив общую часть (диск, virt-install, --wait, IP, /etc/hosts) без изменений.

**Поддержка cloud-образов (qcow2)** как альтернативный, гораздо более быстрый режим (секунды вместо 10+ минут): overlay-диск поверх готового
cloud-образа + cloud-init NoCloud вместо kickstart/OEMDRV — свой режим
`install_mode: iso|cloud-image` в `vars.yml`.

**Статический IP** — опция `vm_ip_static` в kickstart вместо dhcp, для сценариев, где тестовой инфраструктуре нужны предсказуемые адреса.

