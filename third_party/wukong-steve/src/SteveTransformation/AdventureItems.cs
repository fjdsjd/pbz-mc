using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace SteveTransformation;

internal static class AdventureItems
{
    internal static readonly McItem[] Swords={McItem.WoodenSword,McItem.StoneSword,McItem.CopperSword,McItem.IronSword,McItem.GoldenSword,McItem.Sword,McItem.NetheriteSword};
    internal static readonly McItem[] Pickaxes={McItem.WoodenPickaxe,McItem.StonePickaxe,McItem.CopperPickaxe,McItem.IronPickaxe,McItem.GoldenPickaxe,McItem.Pickaxe,McItem.NetheritePickaxe};
    internal static readonly string[] Materials={"wooden","stone","copper","iron","golden","diamond","netherite"};
    internal static readonly string[] MaterialNames={"木","石","铜","铁","金","钻石","下界合金"};
    internal static readonly string[] ArmorMaterials={"leather","copper","chainmail","iron","golden","diamond","netherite"};
    internal static readonly string[] ArmorNames={"皮革","铜","锁链","铁","金","钻石","下界合金"};
    internal static readonly string[] ArmorParts={"helmet","chestplate","leggings","boots"};
    internal static readonly string[] ArmorPartNames={"头盔","胸甲","护腿","靴子"};
    internal static bool IsSword(McItem item)=>Array.IndexOf(Swords,item)>=0;
    internal static bool IsPickaxe(McItem item)=>Array.IndexOf(Pickaxes,item)>=0;
    internal static bool IsArmor(McItem item)=>item>=McItem.LeatherHelmet && item<=McItem.NetheriteBoots;
    internal static int ArmorSlot(McItem item)=>IsArmor(item)?((int)item-(int)McItem.LeatherHelmet)%4:-1;
    internal static int ArmorMaterial(McItem item)=>IsArmor(item)?((int)item-(int)McItem.LeatherHelmet)/4:-1;
    internal static bool Weapon(McItem item)=>IsSword(item)||MinecraftWeapons.IsSpear(item)||MinecraftWeapons.IsMace(item)||item==McItem.Bow||item==McItem.Trident;
    internal static bool Permanent(McItem item)=>Weapon(item)||IsArmor(item)||IsPickaxe(item)||item==McItem.Shield||item==McItem.Flint||item==McItem.HealingBottle;
    internal static bool Reinforceable(McItem item)=>Weapon(item)||IsArmor(item)||IsPickaxe(item)||item==McItem.Shield;
    internal static int StackLimit(McItem item)=>Permanent(item)?1:64;
    internal static bool Exchangeable(McItem item)=>IsSword(item)||IsArmor(item)||item==McItem.GoldenApple||item==McItem.Dirt||item==McItem.Stone;
    internal static string? Asset(McItem item)
    {
        int sword=Array.IndexOf(Swords,item),pickaxe=Array.IndexOf(Pickaxes,item);
        if(sword>=0) return Materials[sword]+"_sword";
        if(pickaxe>=0) return Materials[pickaxe]+"_pickaxe";
        if(IsArmor(item)) return ArmorMaterials[ArmorMaterial(item)]+"_"+ArmorParts[ArmorSlot(item)];
        return item switch {McItem.LifeCrystal=>"life_crystal",McItem.LifeShard=>"life_shard",McItem.HealingBottle=>"healing_bottle",
            McItem.BottleCapacity=>"bottle_capacity",McItem.BottleStrength=>"bottle_strength",McItem.PrizeTicket=>"prize_ticket",McItem.LuckyClover=>"lucky_clover",_=>null};
    }
    internal static string? Label(McItem item)
    {
        int sword=Array.IndexOf(Swords,item),pickaxe=Array.IndexOf(Pickaxes,item);
        if(sword>=0) return MaterialNames[sword]+"剑";
        if(pickaxe>=0) return MaterialNames[pickaxe]+"镐";
        if(IsArmor(item)) return ArmorNames[ArmorMaterial(item)]+ArmorPartNames[ArmorSlot(item)];
        return item switch {McItem.LifeCrystal=>"生命水晶",McItem.LifeShard=>"生命碎片",McItem.HealingBottle=>"治疗瓶",
            McItem.BottleCapacity=>"治疗瓶扩容石",McItem.BottleStrength=>"治疗精华",McItem.PrizeTicket=>"祈愿券",McItem.LuckyClover=>"幸运四叶草",_=>null};
    }
    internal static double Reinforcement(int level)=>1+.04*Math.Max(0,Math.Min(15,level));
    // Adventure progression is independent of native equipment; gold is a lateral material branch.
    internal static double BaseAttack(McItem item)
    {
        int material=Array.IndexOf(Swords,item);
        if(material>=0) return new[]{30d,39,50.7,65.91,44,85.683,111.3879}[material];
        if(MinecraftWeapons.IsSpear(item)) return new[]{31d,40.3,52.39,68.107,46,88.5391,115.10083}[MinecraftWeapons.Material(item)];
        if(item==McItem.Bow) return 64;
        if(item==McItem.Trident) return 88;
        if(MinecraftWeapons.IsMace(item)) return 82;
        if(IsPickaxe(item)) return 18+8*Array.IndexOf(Pickaxes,item);
        return 8;
    }
    internal static double BaseDefense(McItem item)=>IsArmor(item)
        ?new[]{18d,23.4,27,30.42,22,39.546,51.4098}[ArmorMaterial(item)]*new[]{.8,1.4,1.1,.7}[ArmorSlot(item)]:0;
    internal static int MaterialTier(McItem item)
    {
        int material=IsArmor(item)?ArmorMaterial(item):IsSword(item)?Array.IndexOf(Swords,item):IsPickaxe(item)?Array.IndexOf(Pickaxes,item):MinecraftWeapons.IsSpear(item)?MinecraftWeapons.Material(item):-1;
        return material switch {0=>0,1=>1,2=>2,3=>3,4=>2,5=>4,6=>5,_=>item==McItem.Bow||item==McItem.Shield||item==McItem.Flint||item==McItem.HealingBottle?1:3};
    }
    internal static readonly Dictionary<string,(string Label,int Max)> Enchantments=new Dictionary<string,(string,int)>(StringComparer.Ordinal)
    {
        ["sharpness"]=("锋利",5),["sweeping"]=("横扫之刃",3),["knockback"]=("击退",2),["fire"]=("火焰附加",2),
        ["power"]=("力量",5),["punch"]=("冲击",2),["flame"]=("火矢",1),["infinity"]=("无限",1),
        ["density"]=("致密",5),["breach"]=("破甲",4),["wind"]=("风爆",3),["lunge"]=("突进",3),
        ["loyalty"]=("忠诚",3),["channeling"]=("引雷",1),["impaling"]=("穿刺",5),
        ["protection"]=("保护",4),["blast"]=("爆炸保护",4),["projectile"]=("弹射物保护",4),["fire_protection"]=("火焰保护",4),["feather"]=("摔落保护",4),["efficiency"]=("效率",5)
    };
    internal static Dictionary<string,int> ParseEnchantments(string signature)
    {
        var result=new Dictionary<string,int>(StringComparer.Ordinal);
        if(string.IsNullOrEmpty(signature)) return result;
        foreach(string entry in signature.Split(';'))
        {
            var pair=entry.Split('=');
            if(pair.Length!=2||!Enchantments.TryGetValue(pair[0],out var rule)||!int.TryParse(pair[1],NumberStyles.None,CultureInfo.InvariantCulture,out int level)||level<1||level>rule.Max||result.ContainsKey(pair[0]))
                throw new ArgumentException("Invalid enchantment signature");
            result.Add(pair[0],level);
        }
        return result;
    }
    internal static string Signature(McItem item,string enchantments)
    {
        var entries=ParseEnchantments(enchantments);
        foreach(var key in entries.Keys)
        {
            bool valid=key=="sharpness"||key=="knockback"||key=="fire"?IsSword(item)||MinecraftWeapons.IsSpear(item):
                key=="sweeping"?IsSword(item):key=="power"||key=="punch"||key=="flame"||key=="infinity"?item==McItem.Bow:
                key=="density"||key=="breach"||key=="wind"?MinecraftWeapons.IsMace(item):key=="lunge"?MinecraftWeapons.IsSpear(item):
                key=="loyalty"||key=="channeling"||key=="impaling"?item==McItem.Trident:key=="feather"?ArmorSlot(item)==3:key=="efficiency"?IsPickaxe(item):IsArmor(item);
            if(!valid) throw new ArgumentException("Enchantment does not support this item");
        }
        if(entries.ContainsKey("density")&&entries.ContainsKey("breach")) throw new ArgumentException("Density and breach are incompatible");
        if(new[]{"protection","blast","projectile","fire_protection"}.Count(entries.ContainsKey)>1) throw new ArgumentException("Protection enchantments are mutually exclusive");
        return string.Join(";",entries.OrderBy(p=>p.Key,StringComparer.Ordinal).Select(p=>p.Key+"="+p.Value));
    }
    internal static string EnchantmentLabel(string signature)=>string.Join(" · ",ParseEnchantments(signature).Select(p=>Enchantments[p.Key].Label+" "+new[]{"","I","II","III","IV","V"}[p.Value]));
    internal static (McItem Item,string Enchantments) Normalize(McItem item,string signature="")
    {
        if(item>=McItem.MaceDensity&&item<=McItem.MaceBreachWind)
        {
            signature=item switch {McItem.MaceDensity=>"density=5",McItem.MaceBreach=>"breach=4",McItem.MaceWindI=>"wind=1",McItem.MaceWindII=>"wind=2",McItem.MaceWindIII=>"wind=3",McItem.MaceDensityWind=>"density=5;wind=3",_=>"breach=4;wind=3"};
            item=McItem.Mace;
        }
        else if(MinecraftWeapons.IsSpear(item)&&MinecraftWeapons.Lunge(item)>0) {signature="lunge="+MinecraftWeapons.Lunge(item);item=(McItem)((int)McItem.WoodenSpear+MinecraftWeapons.Material(item));}
        return (item,Signature(item,signature));
    }
}
