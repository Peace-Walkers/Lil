ages = [0]
i = 1

while i < 100000:
    ages.append(i)
    i += 1

doubled = list(map(lambda x: x * 2, ages))
filtred = list(filter(lambda x: x < 50000, doubled))
