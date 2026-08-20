#!/bin/bash

#Скрипт который обновляет сервисы 

#При распаковке права сохраняются (так же как и при cat)
# Нужно чтобы папка называлась именно г.м.ч-webapi.zip
#Переходим в директорию со скриптом (там должен храниться только один архив .zip с джарниками)
DIRECTORY="$(dirname "$(readlink -f "$0")")"
echo "ПУТЬ ГДЕ ЛЕЖИТ АРХИВ И САМ СКРИПТ : $DIRECTORY"

for i in $(unzip -l "$DIRECTORY/$(date +'%Y.%m.%d')-webapi.zip"|grep '\.jar$'|awk '{print $NF}')
do
  echo "i=$i"
  serviceName=$(echo $i|awk -F '/bin/' '{print $2}'|sed 's/\.jar$//') #название приложения
  echo "serviceName=$serviceName"
  destPath=$(echo $i|awk -F '-webapi' '{print $2}') #путь, куда залить новую сборку
  echo "destPath=$destPath"
  echo "Начал обновлять приложение $serviceName"
  echo "destPath=$destPath"
  systemctl stop $serviceName
  cd "$(dirname "$(readlink -f "$0")")" #Переход в директорию, где лежит сам скрипт
#pwd
  ls -lA *.zip
  unzip -p *.zip $i > $destPath
  systemctl start $serviceName
  echo -e "Закончил обновлять приложение $serviceName\n"
  sleep 50
done

