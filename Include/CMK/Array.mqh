void Concat1DULong(ulong &arr[], ulong data) {
   int currentSize = ArraySize(arr);
   ArrayResize(arr, currentSize + 1);
   arr[currentSize] = data;
}

// Initialize sizes: planes = P, rows per plane = R
template<typename T>
void InitJagged3D(T &arr[][][], int P, int R) {
   ArrayResize(arr, P);
   for(int p = 0; p < P; ++p) {
      ArrayResize(arr[p], R);
      for(int r = 0; r < R; ++r) {
         ArrayResize(arr[p][r], 0);
      }
   }
}

// push the value in last
template<typename T>
void PushLast3D(T &arr[][][], int p, int r, const T value) {
   int n = ArraySize(arr[p][r]);
   ArrayResize(arr[p][r], n + 1);
   arr[p][r][n] = value;
}