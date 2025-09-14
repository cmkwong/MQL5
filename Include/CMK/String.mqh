// random string
string getRandomString(int strLen, int min = 1, int max = 9) {
   string randStr = "";
   for(int i = 0; i < strLen; i++) {
      int randomIntInRange  = (int)(MathRand() * (max - min + 1) / 32767.0) + min;
      randStr              += (string)(randomIntInRange);
   }
   return randStr;
}