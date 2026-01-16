echo "Fetching web server..."

rm -rf ./goschool/
rm -rf ./goschool-front/

rm -rf ./back/
rm -rf ./front/


echo "Fetching Backend..."
git clone https://github.com/valentinogrande/goschool


echo "Fetching Frontend..."
git clone https://github.com/FranciscoGibbons/goschool-front

mkdir back && mkdir front;

cp -r ./goschool/. ./back/.


cp -r ./goschool-front/. ./front/.

rm ./mysql/init.sql
cp ./goschool/init.sql ./mysql/

rm ./init/create_database.py
cp ./goschool/create_database.py ./init/

rm -rf  goschool/
rm -rf goschool-front/
