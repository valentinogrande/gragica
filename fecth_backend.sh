echo "Fetching backend..."

rm -rf ./goschool/

rm -rf ./back/

git clone https://github.com/valentinogrande/goschool

mkdir back

cp -r ./goschool/. ./back/.

rm ./mysql/init.sql
cp ./goschool/init.sql ./mysql/

rm ./init/create_database.py
cp ./goschool/create_database.py ./init/

rm -rf  goschool/
