// get the current time string, eg: 20250829_095605
string getCurrentTimeString() {
   MqlDateTime tm = {};
   // Get the current time as datetime
   datetime time_server = TimeLocal(tm);
   string   monS        = (string)tm.mon;
   if(StringLen(monS) == 1) {
      monS = "0" + monS;
   }
   string dayS = (string)tm.day;
   if(StringLen(dayS) == 1) {
      dayS = "0" + dayS;
   }
   string hourS = (string)tm.hour;
   if(StringLen(hourS) == 1) {
      hourS = "0" + hourS;
   }
   string minS = (string)tm.min;
   if(StringLen(minS) == 1) {
      minS = "0" + minS;
   }
   string secS = (string)tm.sec;
   if(StringLen(secS) == 1) {
      secS = "0" + secS;
   }
   return (string)tm.year + monS + dayS + "_" + hourS + minS + secS;
}

// add days
datetime AddDate(datetime currDate, int daysToChange) {
   datetime newDate = currDate + (daysToChange * 86400);   // Add 5 days
   return newDate;
}
