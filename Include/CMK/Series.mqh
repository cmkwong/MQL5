template<typename T>
void PushValue(T &arr[], const T value) {
   bool series = ArrayGetAsSeries(arr);
   int  n      = ArraySize(arr);
   ArrayResize(arr, n + 1);

   if(series) {
      // Move existing elements one step to the right to free index 0
      // For large arrays, consider a fixed-size buffer to avoid O(n) shifts.
      for(int i = n; i > 0; --i)
         arr[i] = arr[i - 1];
      arr[0] = value;   // newest at index 0
   } else {
      arr[n] = value;   // append at the end
   }
}