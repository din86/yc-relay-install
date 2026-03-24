# GoKaskad

Чистый bash-скрипт для настройки каскадного проброса трафика через VPS.

Подходит для сценариев вида:

**Клиент → этот сервер → конечный сервер**

Можно использовать для:
- AmneziaWG / WireGuard
- VLESS / XRay
- MTProto / TProxy
- SSH
- RDP
- любых TCP/UDP сервисов

## Возможности

- настройка проброса **TCP** и **UDP**
- одинаковые входящие и исходящие порты
- кастомные правила с разными портами
- автоматическое включение `ip_forward`
- включение `BBR`
- установка `iptables-persistent` и `netfilter-persistent`
- сохранение правил после перезагрузки
- просмотр активных правил
- удаление одного правила
- полный сброс `iptables`
- установка глобальной команды `gokaskad`

## Требования

- Ubuntu / Debian
- root-доступ
- внешний IP на сервере
- открытые нужные порты в firewall / Security Group
- конечный сервер, на который будет идти проброс

## Быстрая установка

Скачивание и запуск одной командой:

```bash
wget -O install.sh https://raw.githubusercontent.com/din86/yc-relay-install/main/install.sh && chmod +x install.sh && sudo ./install.sh
