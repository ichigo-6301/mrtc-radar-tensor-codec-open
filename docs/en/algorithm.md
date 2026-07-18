# Algorithm

RDTC v1 encodes the I and Q components of I16Q16 complex samples separately. ZERO_RICE uses a zero predictor. DELTA_RICE predicts from the previous sample in the same channel. Signed residuals are mapped to non-negative integers before Rice coding.

Each coded payload uses a unary quotient, delimiter zero, and MSB-first remainder. The decoder follows the header payload-bit count and ignores tail padding.
